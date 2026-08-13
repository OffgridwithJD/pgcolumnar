/*-------------------------------------------------------------------------
 * columnar_objstore_module.c
 *		Object-store byte source for pgColumnar (#393).
 *
 * Loaded on demand by PgColumnarObjStoreGet, never preloaded. See
 * src/columnar_objstore.h for why it is a separate library and for the ABI.
 *
 * M1 scope (design/ISSUE_393_M1_HTTP_SOURCE.md): plain-HTTP/1.1 ranged reads,
 * exact object keys only. GET and HEAD are the whole request set. SigV4 (M2)
 * and TLS (M3) layer on top of the same transport; https:// and s3:// report
 * unsupported until then, which is a better failure than a cleartext fallback.
 *
 * Transport rules, which are constraints rather than style:
 *
 * - No blocking syscall ever touches the socket. The backend's signal handlers
 *   are installed with SA_RESTART, so a blocking recv would resume around a
 *   query cancel instead of failing with EINTR; the tree documents the same
 *   failure shape for FIFOs (columnar_parquet_reader.c, pq_path_is_candidate).
 *   Every wait is WaitLatchOrSocket + CHECK_FOR_INTERRUPTS, which is what makes
 *   statement_timeout able to get the backend back mid-transfer.
 *
 * - A server that answers a Range request with 200 is an error, never a silent
 *   whole-object read: the caller sized its buffer for `n` bytes, and "the
 *   wrong bytes quietly" is the failure mode this tree keeps deciding not to
 *   ship.
 *
 * - Sockets are cleaned up on abort through a resource-release callback over
 *   the open-handle list. The invariant that makes close-all-on-abort correct:
 *   no handle survives its statement (every reader materializes and closes
 *   before returning), so a live handle during an abort belongs to the
 *   statement being aborted.
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include "fmgr.h"
#include "lib/ilist.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "storage/fd.h"
#include "storage/latch.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/wait_event.h"

#include "columnar_objstore.h"

PG_MODULE_MAGIC;

PGDLLEXPORT const PgColumnarObjStoreApi *pgcolumnar_objstore_init(void);

/* Response head is bounded before it is parsed; a server cannot size us. */
#define OS_MAX_HEAD		16384
/* Receive staging buffer; body bytes stream through it into the caller's. */
#define OS_RBUF			65536
/* One wait slice; consecutive silent slices add up to the inactivity limit. */
#define OS_WAIT_SLICE_MS	5000
#define OS_MAX_QUIET_SLICES	12	/* 60 s of silence is a dead peer */

struct PgColumnarObjHandle
{
	char	   *url;			/* full URL, for error messages */
	char	   *host;			/* authority, split for connect */
	int			port;
	char	   *abspath;		/* request-target, always starts with '/' */

	int			fd;				/* -1 when disconnected */
	bool		fd_reserved;	/* ReserveExternalFD accounting */
	int64		len;			/* object length from open's HEAD */
	uint64		served;			/* requests completed on this connection */

	/* receive staging */
	uint8	   *rb;
	int			rb_off;			/* consumed up to here */
	int			rb_len;			/* valid bytes */

	dlist_node	node;			/* open-handle list, for abort cleanup */
};

/* One parsed response head. */
typedef struct OsResponse
{
	int			status;
	int64		content_length; /* -1 when absent */
	bool		chunked;
	bool		conn_close;
} OsResponse;

static dlist_head os_open_handles = DLIST_STATIC_INIT(os_open_handles);
static bool os_callback_registered = false;

/* ---------------------------------------------------------------- lifecycle */

static void
os_disconnect(PgColumnarObjHandle *h)
{
	if (h->fd >= 0)
	{
		close(h->fd);
		h->fd = -1;
	}
	if (h->fd_reserved)
	{
		ReleaseExternalFD();
		h->fd_reserved = false;
	}
	h->served = 0;
	h->rb_off = h->rb_len = 0;
}

static void
os_free_handle(PgColumnarObjHandle *h)
{
	os_disconnect(h);
	dlist_delete(&h->node);
	if (h->rb)
		pfree(h->rb);
	if (h->url)
		pfree(h->url);
	if (h->host)
		pfree(h->host);
	if (h->abspath)
		pfree(h->abspath);
	pfree(h);
}

/*
 * Abort cleanup. ereport out of a read unwinds the scan without reaching
 * close(); this returns the socket and the ExternalFD reservation. See the
 * header comment for why closing every handle is correct.
 */
static void
os_resource_release(ResourceReleasePhase phase, bool isCommit,
					bool isTopLevel, void *arg)
{
	if (phase != RESOURCE_RELEASE_AFTER_LOCKS || !isTopLevel)
		return;

	while (!dlist_is_empty(&os_open_handles))
	{
		PgColumnarObjHandle *h =
			dlist_container(PgColumnarObjHandle, node,
							dlist_head_node(&os_open_handles));

		if (isCommit)
			elog(WARNING,
				 "columnar: object-store handle for \"%s\" leaked to commit",
				 h->url);
		os_free_handle(h);
	}
}

/* ------------------------------------------------------------------ waiting */

static void
os_wait(PgColumnarObjHandle *h, uint32 sockEvents, int *quiet)
{
	int			rc;

	rc = WaitLatchOrSocket(MyLatch,
						   WL_LATCH_SET | WL_EXIT_ON_PM_DEATH | sockEvents,
						   h->fd, OS_WAIT_SLICE_MS, PG_WAIT_EXTENSION);
	if (rc & WL_LATCH_SET)
		ResetLatch(MyLatch);
	CHECK_FOR_INTERRUPTS();

	if (rc & (WL_SOCKET_READABLE | WL_SOCKET_WRITEABLE))
		*quiet = 0;
	else if (++(*quiet) >= OS_MAX_QUIET_SLICES)
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("columnar: timeout reading \"%s\"", h->url),
				 errdetail("The server sent nothing for %d seconds.",
						   OS_MAX_QUIET_SLICES * OS_WAIT_SLICE_MS / 1000)));
}

/* ---------------------------------------------------------------- connect */

static void
os_connect(PgColumnarObjHandle *h)
{
	struct addrinfo hints;
	struct addrinfo *addrs = NULL;
	struct addrinfo *ai;
	char		portstr[16];
	int			rc;
	int			quiet = 0;

	Assert(h->fd < 0);

	if (!h->fd_reserved)
	{
		if (!AcquireExternalFD())
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
					 errmsg("columnar: no file descriptor available to read \"%s\"",
							h->url)));
		h->fd_reserved = true;
	}

	/*
	 * Name resolution is synchronous in M1. The fixture and the ordinary
	 * endpoint form are IP literals, which never block; a DNS name against a
	 * slow resolver blocks here and is a known, documented M1 limitation
	 * rather than a socket-wait violation.
	 */
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	snprintf(portstr, sizeof(portstr), "%d", h->port);
	rc = getaddrinfo(h->host, portstr, &hints, &addrs);
	if (rc != 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("columnar: could not resolve \"%s\": %s",
						h->host, gai_strerror(rc))));

	for (ai = addrs; ai != NULL; ai = ai->ai_next)
	{
		h->fd = socket(ai->ai_family, SOCK_STREAM, 0);
		if (h->fd < 0)
			continue;
		if (fcntl(h->fd, F_SETFL, O_NONBLOCK) < 0)
		{
			close(h->fd);
			h->fd = -1;
			continue;
		}

		if (connect(h->fd, ai->ai_addr, ai->ai_addrlen) == 0)
			break;
		if (errno == EINPROGRESS)
		{
			socklen_t	errlen = sizeof(rc);

			do
			{
				os_wait(h, WL_SOCKET_WRITEABLE, &quiet);
				rc = -1;
				if (getsockopt(h->fd, SOL_SOCKET, SO_ERROR, &rc, &errlen) < 0)
					rc = errno;
			} while (rc == EINPROGRESS || rc == EALREADY);
			if (rc == 0)
				break;
			errno = rc;
		}
		close(h->fd);
		h->fd = -1;
	}
	freeaddrinfo(addrs);

	if (h->fd < 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("columnar: could not connect to \"%s\": %m", h->url)));

	rc = 1;
	(void) setsockopt(h->fd, IPPROTO_TCP, TCP_NODELAY, &rc, sizeof(rc));
	h->served = 0;
	h->rb_off = h->rb_len = 0;
}

/* ------------------------------------------------------------------- send */

/*
 * Send the whole request. Returns false on a connection-level failure so the
 * caller can retry once on a stale keep-alive connection; raises for anything
 * that a fresh connection cannot fix.
 */
static bool
os_send_all(PgColumnarObjHandle *h, const char *buf, size_t len)
{
	int			quiet = 0;

	while (len > 0)
	{
		ssize_t		sent = send(h->fd, buf, len, MSG_NOSIGNAL);

		if (sent > 0)
		{
			buf += sent;
			len -= (size_t) sent;
			continue;
		}
		if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
		{
			os_wait(h, WL_SOCKET_WRITEABLE, &quiet);
			continue;
		}
		if (sent < 0 && errno == EINTR)
			continue;
		return false;			/* EPIPE, ECONNRESET, ... : maybe stale */
	}
	return true;
}

/* ------------------------------------------------------------------- recv */

/* Pull more bytes into the staging buffer. Returns false on orderly EOF. */
static bool
os_fill(PgColumnarObjHandle *h)
{
	int			quiet = 0;

	if (h->rb_off == h->rb_len)
		h->rb_off = h->rb_len = 0;
	else if (h->rb_len == OS_RBUF)
	{
		memmove(h->rb, h->rb + h->rb_off, h->rb_len - h->rb_off);
		h->rb_len -= h->rb_off;
		h->rb_off = 0;
	}

	for (;;)
	{
		ssize_t		got = recv(h->fd, h->rb + h->rb_len,
							   OS_RBUF - h->rb_len, 0);

		if (got > 0)
		{
			h->rb_len += (int) got;
			return true;
		}
		if (got == 0)
			return false;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
		{
			os_wait(h, WL_SOCKET_READABLE, &quiet);
			continue;
		}
		if (errno == EINTR)
			continue;
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("columnar: could not read from \"%s\": %m", h->url)));
	}
}

/* --------------------------------------------------------------- response */

/*
 * Read and parse one response head. Returns false when the connection died
 * before a single status byte arrived (the stale keep-alive case); raises on
 * everything else.
 */
static bool
os_read_head(PgColumnarObjHandle *h, OsResponse *resp)
{
	int			headEnd = -1;

	memset(resp, 0, sizeof(*resp));
	resp->content_length = -1;

	for (;;)
	{
		int			avail = h->rb_len - h->rb_off;
		const char *p = (const char *) h->rb + h->rb_off;
		int			i;

		for (i = 0; i + 3 < avail; i++)
			if (memcmp(p + i, "\r\n\r\n", 4) == 0)
			{
				headEnd = i + 4;
				break;
			}
		if (headEnd >= 0)
			break;
		if (avail >= OS_MAX_HEAD)
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("columnar: oversized HTTP response header from \"%s\"",
							h->url)));
		if (!os_fill(h))
		{
			if (h->rb_len - h->rb_off == 0)
				return false;	/* clean EOF before any byte: stale */
			ereport(ERROR,
					(errcode(ERRCODE_CONNECTION_FAILURE),
					 errmsg("columnar: connection to \"%s\" closed mid-response",
							h->url)));
		}
	}

	{
		const char *head;
		const char *line;
		const char *end;

		/*
		 * NUL-terminate the head (over its final LF) so the strstr calls
		 * below cannot run past the staging buffer: rb is not a C string, and
		 * an unbounded strstr reads whatever follows the allocation until it
		 * happens upon a zero byte.
		 */
		h->rb[h->rb_off + headEnd - 1] = '\0';
		head = (const char *) h->rb + h->rb_off;
		line = head;
		end = head + headEnd;

		if (headEnd < 12 || strncmp(head, "HTTP/1.", 7) != 0)
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("columnar: \"%s\" did not answer HTTP", h->url)));
		resp->status = atoi(head + 9);

		while (line < end)
		{
			const char *eol = memchr(line, '\n', end - line);

			if (eol == NULL)
				break;
			if (pg_strncasecmp(line, "Content-Length:", 15) == 0)
				resp->content_length = strtoll(line + 15, NULL, 10);
			else if (pg_strncasecmp(line, "Transfer-Encoding:", 18) == 0 &&
					 strstr(line, "chunked") != NULL && strstr(line, "chunked") < eol)
				resp->chunked = true;
			else if (pg_strncasecmp(line, "Connection:", 11) == 0 &&
					 strstr(line, "close") != NULL && strstr(line, "close") < eol)
				resp->conn_close = true;
			line = eol + 1;
		}
	}

	h->rb_off += headEnd;
	return true;
}

/* Take min(n, buffered) bytes from staging into dst (or discard). */
static int64
os_take(PgColumnarObjHandle *h, uint8 *dst, int64 n)
{
	int64		avail = h->rb_len - h->rb_off;
	int64		take = Min(n, avail);

	if (take > 0 && dst != NULL)
		memcpy(dst, h->rb + h->rb_off, take);
	h->rb_off += (int) take;
	return take;
}

/* Read exactly n body bytes into dst (NULL discards). */
static void
os_read_exact(PgColumnarObjHandle *h, uint8 *dst, int64 n)
{
	while (n > 0)
	{
		int64		got = os_take(h, dst, n);

		if (dst != NULL)
			dst += got;
		n -= got;
		if (n > 0 && !os_fill(h))
			ereport(ERROR,
					(errcode(ERRCODE_CONNECTION_FAILURE),
					 errmsg("columnar: connection to \"%s\" closed mid-body",
							h->url)));
	}
}

/* Read one CRLF-terminated line (chunk framing) into buf; bounded. */
static void
os_read_line(PgColumnarObjHandle *h, char *buf, size_t cap)
{
	size_t		used = 0;

	for (;;)
	{
		while (h->rb_off < h->rb_len)
		{
			char		c = (char) h->rb[h->rb_off++];

			if (c == '\n')
			{
				buf[used] = '\0';
				return;
			}
			if (c != '\r')
			{
				if (used + 1 >= cap)
					ereport(ERROR,
							(errcode(ERRCODE_PROTOCOL_VIOLATION),
							 errmsg("columnar: oversized chunk header from \"%s\"",
									h->url)));
				buf[used++] = c;
			}
		}
		if (!os_fill(h))
			ereport(ERROR,
					(errcode(ERRCODE_CONNECTION_FAILURE),
					 errmsg("columnar: connection to \"%s\" closed mid-body",
							h->url)));
	}
}

/*
 * Consume a response body. dst != NULL requires the body to be exactly `want`
 * bytes; dst == NULL discards a body of any length (error pages, HEAD has
 * none and must not call this).
 */
static void
os_read_body(PgColumnarObjHandle *h, const OsResponse *resp,
			 uint8 *dst, int64 want)
{
	if (resp->chunked)
	{
		char		line[64];
		int64		total = 0;

		for (;;)
		{
			int64		sz;

			os_read_line(h, line, sizeof(line));
			sz = strtoll(line, NULL, 16);
			if (sz < 0)
				ereport(ERROR,
						(errcode(ERRCODE_PROTOCOL_VIOLATION),
						 errmsg("columnar: bad chunk size from \"%s\"", h->url)));
			if (sz == 0)
			{
				/* trailers until the empty line */
				do
				{
					os_read_line(h, line, sizeof(line));
				} while (line[0] != '\0');
				break;
			}
			if (dst != NULL && total + sz > want)
				ereport(ERROR,
						(errcode(ERRCODE_PROTOCOL_VIOLATION),
						 errmsg("columnar: \"%s\" sent more bytes than requested",
								h->url)));
			os_read_exact(h, dst ? dst + total : NULL, sz);
			total += sz;
			os_read_line(h, line, sizeof(line));	/* chunk-terminating CRLF */
		}
		if (dst != NULL && total != want)
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("columnar: \"%s\" sent %lld of %lld requested bytes",
							h->url, (long long) total, (long long) want)));
	}
	else
	{
		int64		cl = resp->content_length;

		if (cl < 0)
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("columnar: \"%s\" sent a body with no length", h->url)));
		if (dst != NULL && cl != want)
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("columnar: \"%s\" sent %lld of %lld requested bytes",
							h->url, (long long) cl, (long long) want)));
		os_read_exact(h, dst, cl);
	}
}

/* ---------------------------------------------------------------- request */

/*
 * One request/response cycle with a single reconnect on a stale keep-alive
 * connection. `off`/`n` describe the Range for GET; HEAD sends no Range.
 */
static void
os_request(PgColumnarObjHandle *h, const char *method,
		   int64 off, int64 n, OsResponse *resp)
{
	StringInfoData req;
	bool		isGet = (strcmp(method, "GET") == 0);
	int			attempt;

	initStringInfo(&req);
	appendStringInfo(&req, "%s %s HTTP/1.1\r\nHost: %s:%d\r\n",
					 method, h->abspath, h->host, h->port);
	if (isGet)
		appendStringInfo(&req, "Range: bytes=%lld-%lld\r\n",
						 (long long) off, (long long) (off + n - 1));
	appendStringInfoString(&req, "User-Agent: pgcolumnar-objstore/1\r\n\r\n");

	for (attempt = 0;; attempt++)
	{
		bool		fresh = (h->fd < 0);

		if (h->fd < 0)
			os_connect(h);

		if (os_send_all(h, req.data, req.len) && os_read_head(h, resp))
			break;

		/*
		 * The connection failed before a status byte. On a connection that
		 * already served a request this is the ordinary keep-alive race and is
		 * retried once on a fresh connection; on a fresh connection it is the
		 * server's answer and is an error.
		 */
		os_disconnect(h);
		if (fresh || attempt > 0)
			ereport(ERROR,
					(errcode(ERRCODE_CONNECTION_FAILURE),
					 errmsg("columnar: connection to \"%s\" failed before a response",
							h->url)));
	}

	pfree(req.data);
}

/* -------------------------------------------------------------------- ABI */

static bool
objstore_handles_url(const char *url)
{
	/*
	 * Plain http:// only in M1. https:// and s3:// stay unhandled so they
	 * report "no such URL scheme" rather than silently downgrading to
	 * cleartext; they arrive with M3 and M2 respectively.
	 */
	return pg_strncasecmp(url, "http://", 7) == 0;
}

static PgColumnarObjHandle *
objstore_open(const char *url, int64 *len)
{
	PgColumnarObjHandle *h;
	OsResponse	resp;
	const char *authority = url + 7;
	const char *slash = strchr(authority, '/');
	const char *colon;
	MemoryContext oldcxt;

	if (!os_callback_registered)
	{
		RegisterResourceReleaseCallback(os_resource_release, NULL);
		os_callback_registered = true;
	}

	if (slash == NULL || slash == authority)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("columnar: \"%s\" has no object path", url)));
	if (memchr(authority, '@', slash - authority) != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("columnar: userinfo in \"%s\" is not supported", url)));

	/*
	 * The handle and its buffers live in TopMemoryContext and are freed
	 * explicitly (close, or the release callback on abort): the per-scan
	 * context this open runs in dies during an abort BEFORE the callback
	 * walks the list, and a handle in that context would be freed memory by
	 * the time the callback closes its socket.
	 */
	oldcxt = MemoryContextSwitchTo(TopMemoryContext);
	h = (PgColumnarObjHandle *) palloc0(sizeof(PgColumnarObjHandle));
	h->fd = -1;
	h->url = pstrdup(url);
	h->abspath = pstrdup(slash);
	colon = memchr(authority, ':', slash - authority);
	if (colon != NULL)
	{
		h->host = pnstrdup(authority, colon - authority);
		h->port = atoi(colon + 1);
	}
	else
	{
		h->host = pnstrdup(authority, slash - authority);
		h->port = 80;
	}
	h->rb = (uint8 *) palloc(OS_RBUF);
	MemoryContextSwitchTo(oldcxt);

	if (h->port <= 0 || h->port > 65535 || h->host[0] == '\0')
	{
		dlist_push_head(&os_open_handles, &h->node);	/* so free can delete */
		os_free_handle(h);
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("columnar: \"%s\" has an invalid host or port", url)));
	}

	dlist_push_head(&os_open_handles, &h->node);

	os_request(h, "HEAD", 0, 0, &resp);
	if (resp.status == 404)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_FILE),
				 errmsg("columnar: \"%s\" does not exist (HTTP 404)", url)));
	if (resp.status != 200)
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg("columnar: unexpected HTTP status %d for \"%s\"",
						resp.status, url)));
	if (resp.content_length < 0)
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg("columnar: \"%s\" reported no length", url)));
	/* HEAD carries no body, whatever its headers say about one. */
	if (resp.conn_close)
		os_disconnect(h);
	else
		h->served++;

	h->len = resp.content_length;
	*len = h->len;
	return h;
}

static void
objstore_read(PgColumnarObjHandle *h, int64 off, void *buf, size_t n)
{
	OsResponse	resp;

	Assert(h != NULL && n > 0);

	os_request(h, "GET", off, (int64) n, &resp);

	if (resp.status == 200)
	{
		/*
		 * The server ignored the Range header. Refuse rather than read: the
		 * caller asked for n bytes and a whole-object body silently desyncs
		 * every later read on this connection.
		 */
		os_disconnect(h);
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg("columnar: \"%s\" ignored a Range request", h->url),
				 errdetail("The server answered 200 with the whole object "
						   "instead of 206 with the requested bytes.")));
	}
	if (resp.status == 404)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_FILE),
				 errmsg("columnar: \"%s\" does not exist (HTTP 404)", h->url)));
	if (resp.status != 206)
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg("columnar: unexpected HTTP status %d for \"%s\"",
						resp.status, h->url)));

	os_read_body(h, &resp, (uint8 *) buf, (int64) n);

	if (resp.conn_close)
		os_disconnect(h);
	else
		h->served++;
}

static void
objstore_close(PgColumnarObjHandle *h)
{
	if (h != NULL)
		os_free_handle(h);
}

static const PgColumnarObjStoreApi objstore_api = {
	.abi_version = PGCOLUMNAR_OBJSTORE_ABI,
	.handles_url = objstore_handles_url,
	.open = objstore_open,
	.read = objstore_read,
	.close = objstore_close,
};

const PgColumnarObjStoreApi *
pgcolumnar_objstore_init(void)
{
	return &objstore_api;
}
