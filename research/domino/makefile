PROGRAM=curltest
TARGET=curltest
SOURCE= $(PROGRAM).cpp
OBJECT = $(PROGRAM).o

CC=g++
CCOPTS=-c -m64
NOTESDIR=$(Notes_ExecDirectory)

# Standalone libcurl test - statically links a from-source-built libcurl.a
# (NOT the copy bundled inside libnotes.so). No static libcurl.a package is
# available on this build machine, so curl is built from source with
# --disable-shared --enable-static (see D:\claude\curl notes). Override
# CURL_SRC_DIR/OPENSSL_SRC_DIR/ZLIB_SRC_DIR to wherever those were built, e.g.:
#   make CURL_SRC_DIR=/depends/curl OPENSSL_SRC_DIR=/depends/openssl ZLIB_SRC_DIR=/depends/zlib
# (that's exactly what capi-container.sh sets via env, matching
# nashcom-build-artifacts' own <ARTIFACTS_DIR>/latest layout: curl and zlib
# always install to lib/, openssl varies between lib/ and lib64/ by platform.)
CURL_LIB    = $(CURL_SRC_DIR)/lib/libcurl.a
SSL_LIBDIR := $(wildcard $(OPENSSL_SRC_DIR)/lib64 $(OPENSSL_SRC_DIR)/lib)
SSL_LIB     = $(SSL_LIBDIR)/libssl.a
CRYPTO_LIB  = $(SSL_LIBDIR)/libcrypto.a
ZLIB_LIB    = $(ZLIB_SRC_DIR)/lib/libz.a

# $(CURL_LIB) must come before -lnotes: our own object file has an
# unversioned, undefined reference to curl_version (and friends) - the
# linker resolves undefined symbols left to right, and libnotes.so's
# entire export table (including its own privately-versioned curl_version)
# is available to satisfy that regardless of static-archive rules, UNLESS
# our own static libcurl.a resolves it first by appearing earlier on the
# command line. Confirmed empirically: with -lnotes first, curl_version
# and the dlsym'd notes_curl_version resolved to the identical address;
# with $(CURL_LIB) first, they resolved to genuinely different addresses.
#
# $(CURL_LIB) appears a second time, right before $(SSL_LIB)/$(CRYPTO_LIB):
# libcurl.a itself has undefined references into OpenSSL (EVP_*, MD5_*,
# etc.), which only resolve if a static archive providing them appears
# later on the command line - hence resolving curl a second time here,
# immediately followed by static OpenSSL. $(ZLIB_LIB) is last since it's
# only needed for OpenSSL's/curl's own compression symbols - originally
# this was a dynamic -lz (a system libz was available on that machine), but
# the capi container has no system libz at all ("cannot find -lz"), so this
# links our own static build instead.
LIBS=$(CURL_LIB) -lnotes -lm -lpthread -lc -ldl $(CURL_LIB) $(SSL_LIB) $(CRYPTO_LIB) $(ZLIB_LIB)

INCDIR      = $(LOTUS)/notesapi/include
CURL_INCDIR = $(CURL_SRC_DIR)/include
OPENSSL_INCDIR = $(OPENSSL_SRC_DIR)/include
BOOTOBJS = $(LOTUS)/notesapi/lib/linux64/notes0.o $(LOTUS)/notesapi/lib/linux64/notesai0.o
DEFINES = -DGCC3 -DGCC4 -fno-strict-aliasing -DGCC_LBLB_NOT_SUPPORTED -Wformat -Wall -Wcast-align -Wconversion  -DUNIX -DLINUX -DLINUX86 -DND64 -DLINUX64 -DW -DLINUX86_64 -DDTRACE -DPTHREAD_KERNEL -D_REENTRANT -DUSE_THREADSAFE_INTERFACES -D_POSIX_THREAD_SAFE_FUNCTIONS  -DHANDLE_IS_32BITS -DHAS_IOCP -DHAS_BOOL -DHAS_DLOPEN -DUSE_PTHREAD_INTERFACES -DLARGE64_FILES -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -DNDUNIX64 -DLONGIS64BIT -DPRODUCTION_VERSION -DOVERRIDEDEBUG -fPIC -Wno-write-strings

$(TARGET): $(OBJECT)
	$(CC) $(OBJECT) $(BOOTOBJS) -L$(NOTESDIR) -Wl,-rpath-link -no-pie $(NOTESDIR) $(LIBS) -o $(TARGET)

$(OBJECT): $(SOURCE)
	$(CC) $(CCOPTS) $(DEFINES) -I$(INCDIR) -I$(CURL_INCDIR) -I$(OPENSSL_INCDIR) $(SOURCE) -o $(OBJECT)

install: $(TARGET)
	cp -f $(TARGET) /opt/hcl/domino/notes/latest/linux/$(PROGRAM)
	chmod 755  /opt/hcl/domino/notes/latest/linux/$(PROGRAM)

clean:
	rm -f *.o
	rm -f ./$(TARGET)

all:    $(TARGET)
