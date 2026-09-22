# pgColumnar object-store module (#393).
#
# A SEPARATE shared library on purpose, and not part of MODULE_big. pgColumnar
# loads through shared_preload_libraries, so anything the main library links is
# mapped into the postmaster and inherited by every backend. This one is opened
# with load_external_function on the first read of a remote path and never
# before, so a cluster that reads only local files never maps it.
#
# PostgreSQL packages its own libcurl dependency this way (libpq-oauth): separate
# library, runtime dlopen, separate package.
MODULE_big = pgcolumnar_objstore

OBJS = columnar_objstore_module.o

PGFILEDESC = "pgColumnar object-store byte source"

PG_CPPFLAGS = -I$(realpath $(dir $(firstword $(MAKEFILE_LIST)))../src)

PKG_CONFIG ?= pkg-config

# TLS (#393 M3). OpenSSL is linked into THIS module only -- the preloaded
# library's dependency set is unchanged, which is the reason this module
# exists. Without OpenSSL at build time the module still builds and serves
# http:// and s3://-over-http; https reports that this build has no TLS.
ifeq ($(shell $(PKG_CONFIG) --exists openssl && echo yes),yes)
PG_CPPFLAGS += -DHAVE_OBJSTORE_OPENSSL $(shell $(PKG_CONFIG) --cflags openssl)
SHLIB_LINK += $(shell $(PKG_CONFIG) --libs openssl)
endif

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

# Header dependencies, for the reason in the top-level Makefile (#1158): PGXS
# emits none unless the server was configured with --enable-depend, and none of
# the servers here was. This module is one object, and it includes a header from
# src/, so the same silent staleness applies.
PG_CFLAGS += -MMD -MP

# Match the language standard the main library uses, for the same reason: PG19's
# headers are C23 and GCC 13 spells it gnu2x while GCC 14 spells it gnu23.
PG_MAJORVERSION := $(shell $(PG_CONFIG) --version | sed -E 's/[^0-9]*([0-9]+).*/\1/')
ifeq ($(shell test "$(PG_MAJORVERSION)" -ge 19 && echo yes),yes)
C23_STD := $(shell echo 'int main(void){return 0;}' \
	| cc -std=gnu23 -x c -c -o /dev/null - >/dev/null 2>&1 && echo gnu23 || echo gnu2x)
PG_CFLAGS += -std=$(C23_STD)
else
PG_CFLAGS += -std=gnu17
endif

include $(PGXS)

-include $(OBJS:.o=.d)

clean: depclean
depclean:
	rm -f $(OBJS:.o=.d)
.PHONY: depclean
