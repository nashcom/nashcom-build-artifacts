/* curltest.cpp - Minimal Domino server add-in that links against a
   separately-deployed, standalone libcurl SDK (see mswin64.mak's
   CURL_SDK_DIR on Windows, CURL_SRC_DIR/OPENSSL_SRC_DIR/ZLIB_SRC_DIR in
   the Linux makefile) instead of the copy bundled inside
   nnotes.dll/libnotes.so.

   Purpose: Domino's own internal curl usage shares global state
   (curl_global_init/curl_global_cleanup) with anything else in the same
   process that also links a copy of curl. This test checks whether using
   a fully separate, own libcurl instance instead works cleanly as a
   Domino servertask, or causes conflicts (e.g. symbol collisions, load
   failures, crashes) by having two independent curl/OpenSSL (here:
   LibreSSL) stacks in the same process.

   init/version/cleanup and a standalone HTTPS GET already confirmed clean.
   This adds triggering curltest.nsf's "curltest" agent (a LotusScript
   NotesHTTPRequest call) via the C-API AgentRun path in between two of our
   own curl_easy_perform() calls, in the same process - to actually test
   whether Domino's own internal curl usage interferes with ours, not just
   assume it based on the exported symbols alone. */

#include <stdio.h>
#include <string.h>

#if defined (NT)
    /* Must come before the Domino headers below - global.h typedefs its
       own HMODULE (as WHANDLE, a generic Domino handle type), and if
       windows.h comes second, GetProcAddress ends up expecting the real
       Win32 HMODULE while our local variables bind to Domino's version
       instead - a type mismatch, not a real error, but the compiler
       reports it as one. */
    #include <windows.h>
#else
    #include <dlfcn.h>
#endif

#include <global.h>
#include <addin.h>
#include <osmisc.h>
#include <osfile.h>
#include <nsfdb.h>
#include <nsfnote.h>
#include <nif.h>
#include <agents.h>
#include <miscerr.h>

#include <curl/curl.h>
#include <openssl/opensslv.h>
#include <openssl/crypto.h>

/* nnotes.dll's own bundled curl functions, loaded explicitly via
   GetProcAddress rather than a .def-based import lib. A .def alias
   (notes_curl_easy_cleanup = curl_easy_cleanup) was tried first, to reach
   these under distinct names without clashing with the standalone
   libcurl-x64.dll symbols above - but that failed to resolve at load time
   even after a clean rebuild, so this uses the well-established explicit-
   linking technique instead: GetModuleHandle (nnotes.dll is already
   loaded, no need for LoadLibrary) + GetProcAddress by real name, called
   through our own function-pointer names. */

typedef char *              (LNPUBLIC  *PFN_NOTES_CURL_VERSION)        (void);
typedef CURLcode            (LNPUBLIC  *PFN_NOTES_CURL_GLOBAL_INIT)    (long flags);
typedef void                (LNPUBLIC  *PFN_NOTES_CURL_GLOBAL_CLEANUP) (void);
typedef CURL *              (LNPUBLIC  *PFN_NOTES_CURL_EASY_INIT)      (void);
typedef CURLcode            (LNVARARGS *PFN_NOTES_CURL_EASY_SETOPT)    (CURL *curl, CURLoption option, ...);
typedef CURLcode            (LNPUBLIC  *PFN_NOTES_CURL_EASY_PERFORM)   (CURL *curl);
typedef void                (LNPUBLIC  *PFN_NOTES_CURL_EASY_CLEANUP)   (CURL *curl);
typedef const char *        (LNPUBLIC  *PFN_NOTES_CURL_EASY_STRERROR)  (CURLcode error);
typedef struct curl_slist * (LNPUBLIC  *PFN_NOTES_CURL_SLIST_APPEND)   (struct curl_slist *list, const char *data);
typedef void                (LNPUBLIC  *PFN_NOTES_CURL_SLIST_FREE_ALL) (struct curl_slist *list);

PFN_NOTES_CURL_VERSION         g_pfnNotesCurlVersion        = NULL;
PFN_NOTES_CURL_GLOBAL_INIT     g_pfnNotesCurlGlobalInit     = NULL;
PFN_NOTES_CURL_GLOBAL_CLEANUP  g_pfnNotesCurlGlobalCleanup  = NULL;
PFN_NOTES_CURL_EASY_INIT       g_pfnNotesCurlEasyInit       = NULL;
PFN_NOTES_CURL_EASY_SETOPT     g_pfnNotesCurlEasySetopt     = NULL;
PFN_NOTES_CURL_EASY_PERFORM    g_pfnNotesCurlEasyPerform    = NULL;
PFN_NOTES_CURL_EASY_CLEANUP    g_pfnNotesCurlEasyCleanup    = NULL;
PFN_NOTES_CURL_EASY_STRERROR   g_pfnNotesCurlEasyStrerror   = NULL;
PFN_NOTES_CURL_SLIST_APPEND    g_pfnNotesCurlSlistAppend    = NULL;
PFN_NOTES_CURL_SLIST_FREE_ALL  g_pfnNotesCurlSlistFreeAll   = NULL;

char g_szTask[]     = "curltest";
char g_szTaskLong[] = "Standalone libcurl Test";

#define CURLTEST_URL         "https://nashcom.de"
#define CURLTEST_AGENT_DB    "curltest.nsf"
#define CURLTEST_AGENT_NAME  "curltest"


typedef struct
{
    char   szBuffer[8192];
    size_t Len;
} CURLTEST_RESPONSE;


size_t WriteCallback (char *pData, size_t Size, size_t NumMemb, void *pUserData)
{
    CURLTEST_RESPONSE *retpResponse = (CURLTEST_RESPONSE *) pUserData;
    size_t TotalSize = Size * NumMemb;
    size_t CopyLen   = TotalSize;

    if ((retpResponse->Len + CopyLen) >= sizeof (retpResponse->szBuffer))
        CopyLen = sizeof (retpResponse->szBuffer) - retpResponse->Len - 1;

    if (CopyLen > 0)
    {
        memcpy (retpResponse->szBuffer + retpResponse->Len, pData, CopyLen);
        retpResponse->Len += CopyLen;
        retpResponse->szBuffer[retpResponse->Len] = '\0';
    }

    /* Always report the full size as consumed, even if our own storage
       truncated - telling curl less would make it think the write failed. */
    return TotalSize;
}


void BuildCaCertPath (size_t cbPath, char *retszPath)
{
    char szDataDir[MAXPATH + 1] = {0};

    OSGetDataDirectory (szDataDir);
    OSPathAddTrailingPathSeparator (szDataDir, (WORD) (sizeof (szDataDir) - 1));

    snprintf (retszPath, cbPath, "%scacert.pem", szDataDir);
}


#if defined (NT)

/* global.h #defines HMODULE as WHANDLE (Domino's own generic handle type,
   see global.h) - needed elsewhere in this file for AddInMain's own
   HMODULE parameter, but GetModuleHandle/GetProcAddress need the real
   Win32 HMODULE. #undef locally so the identifier falls through to the
   genuine windows.h typedef (still valid, just shadowed by the macro),
   then #define it back immediately after so AddInMain is unaffected. */
#undef HMODULE

/* nnotes.dll is already loaded (notes.lib requires it for every standard
   C-API call we make), so GetModuleHandle is enough - no need to
   LoadLibrary it ourselves. Returns FALSE if any function is missing. */

BOOL LoadNotesCurlFunctions (void)
{
    HMODULE hMod = GetModuleHandle ("nnotes.dll");

    if (NULL == hMod)
    {
        AddInLogMessageText ("%s: GetModuleHandle (nnotes.dll) failed", 0, g_szTask);
        return FALSE;
    }

    g_pfnNotesCurlVersion       = (PFN_NOTES_CURL_VERSION)        GetProcAddress (hMod, "curl_version");
    g_pfnNotesCurlGlobalInit    = (PFN_NOTES_CURL_GLOBAL_INIT)    GetProcAddress (hMod, "curl_global_init");
    g_pfnNotesCurlGlobalCleanup = (PFN_NOTES_CURL_GLOBAL_CLEANUP) GetProcAddress (hMod, "curl_global_cleanup");
    g_pfnNotesCurlEasyInit      = (PFN_NOTES_CURL_EASY_INIT)      GetProcAddress (hMod, "curl_easy_init");
    g_pfnNotesCurlEasySetopt    = (PFN_NOTES_CURL_EASY_SETOPT)    GetProcAddress (hMod, "curl_easy_setopt");
    g_pfnNotesCurlEasyPerform   = (PFN_NOTES_CURL_EASY_PERFORM)   GetProcAddress (hMod, "curl_easy_perform");
    g_pfnNotesCurlEasyCleanup   = (PFN_NOTES_CURL_EASY_CLEANUP)   GetProcAddress (hMod, "curl_easy_cleanup");
    g_pfnNotesCurlEasyStrerror  = (PFN_NOTES_CURL_EASY_STRERROR)  GetProcAddress (hMod, "curl_easy_strerror");
    g_pfnNotesCurlSlistAppend   = (PFN_NOTES_CURL_SLIST_APPEND)   GetProcAddress (hMod, "curl_slist_append");
    g_pfnNotesCurlSlistFreeAll  = (PFN_NOTES_CURL_SLIST_FREE_ALL) GetProcAddress (hMod, "curl_slist_free_all");

    if ((NULL == g_pfnNotesCurlVersion)       || (NULL == g_pfnNotesCurlGlobalInit)   ||
        (NULL == g_pfnNotesCurlGlobalCleanup) || (NULL == g_pfnNotesCurlEasyInit)     ||
        (NULL == g_pfnNotesCurlEasySetopt)    || (NULL == g_pfnNotesCurlEasyPerform)  ||
        (NULL == g_pfnNotesCurlEasyCleanup)   || (NULL == g_pfnNotesCurlEasyStrerror) ||
        (NULL == g_pfnNotesCurlSlistAppend)   || (NULL == g_pfnNotesCurlSlistFreeAll))
    {
        AddInLogMessageText ("%s: GetProcAddress failed for one or more nnotes.dll curl functions", 0, g_szTask);
        return FALSE;
    }

    return TRUE;
}

/* Restore Domino's HMODULE for the rest of the file (AddInMain's own
   HMODULE parameter needs it). */
#define HMODULE WHANDLE

#else /* Linux */

/* libnotes.so is already loaded (-lnotes is a required link dependency for
   every standard C-API call we make) - RTLD_NOLOAD gets a handle to the
   already-loaded library without loading a second copy, mirroring
   GetModuleHandle's behavior on Windows. Looking up symbols against this
   SPECIFIC handle (not RTLD_DEFAULT / the global scope) matters here more
   than it did on Windows: our own curl is now statically linked directly
   into this binary (see makefile), so a global-scope lookup could resolve
   to our own symbol instead of libnotes.so's. */

BOOL LoadNotesCurlFunctions (void)
{
    void *hMod = dlopen ("libnotes.so", RTLD_LAZY | RTLD_NOLOAD);

    if (NULL == hMod)
    {
        AddInLogMessageText ("%s: dlopen (libnotes.so, RTLD_NOLOAD) failed: %s", 0, g_szTask, dlerror ());
        return FALSE;
    }

    g_pfnNotesCurlVersion       = (PFN_NOTES_CURL_VERSION)        dlsym (hMod, "curl_version");
    g_pfnNotesCurlGlobalInit    = (PFN_NOTES_CURL_GLOBAL_INIT)    dlsym (hMod, "curl_global_init");
    g_pfnNotesCurlGlobalCleanup = (PFN_NOTES_CURL_GLOBAL_CLEANUP) dlsym (hMod, "curl_global_cleanup");
    g_pfnNotesCurlEasyInit      = (PFN_NOTES_CURL_EASY_INIT)      dlsym (hMod, "curl_easy_init");
    g_pfnNotesCurlEasySetopt    = (PFN_NOTES_CURL_EASY_SETOPT)    dlsym (hMod, "curl_easy_setopt");
    g_pfnNotesCurlEasyPerform   = (PFN_NOTES_CURL_EASY_PERFORM)   dlsym (hMod, "curl_easy_perform");
    g_pfnNotesCurlEasyCleanup   = (PFN_NOTES_CURL_EASY_CLEANUP)   dlsym (hMod, "curl_easy_cleanup");
    g_pfnNotesCurlEasyStrerror  = (PFN_NOTES_CURL_EASY_STRERROR)  dlsym (hMod, "curl_easy_strerror");
    g_pfnNotesCurlSlistAppend   = (PFN_NOTES_CURL_SLIST_APPEND)   dlsym (hMod, "curl_slist_append");
    g_pfnNotesCurlSlistFreeAll  = (PFN_NOTES_CURL_SLIST_FREE_ALL) dlsym (hMod, "curl_slist_free_all");

    if ((NULL == g_pfnNotesCurlVersion)       || (NULL == g_pfnNotesCurlGlobalInit)   ||
        (NULL == g_pfnNotesCurlGlobalCleanup) || (NULL == g_pfnNotesCurlEasyInit)     ||
        (NULL == g_pfnNotesCurlEasySetopt)    || (NULL == g_pfnNotesCurlEasyPerform)  ||
        (NULL == g_pfnNotesCurlEasyCleanup)   || (NULL == g_pfnNotesCurlEasyStrerror) ||
        (NULL == g_pfnNotesCurlSlistAppend)   || (NULL == g_pfnNotesCurlSlistFreeAll))
    {
        AddInLogMessageText ("%s: dlsym failed for one or more libnotes.so curl functions", 0, g_szTask);
        return FALSE;
    }

    return TRUE;
}

#endif


/* One complete GET via our own, separate libcurl - init, perform, log,
   cleanup. Called twice (before/after RunDominoAgent) to see whether
   Domino's own internal curl activity in between disturbs ours. */

void DoCurlGet (const char *pszLabel, const char *pszUrl, const char *pszCaCertPath)
{
    CURL              *pCurl    = NULL;
    CURLcode           Result   = CURLE_OK;
    CURLTEST_RESPONSE  Response = {0};
    long               HttpStatus = 0;

    pCurl = curl_easy_init ();

    if (NULL == pCurl)
    {
        AddInLogMessageText ("%s: [%s] curl_easy_init failed", 0, g_szTask, pszLabel);
        return;
    }

    curl_easy_setopt (pCurl, CURLOPT_URL,            pszUrl);
    curl_easy_setopt (pCurl, CURLOPT_WRITEFUNCTION,  WriteCallback);
    curl_easy_setopt (pCurl, CURLOPT_WRITEDATA,      &Response);
    curl_easy_setopt (pCurl, CURLOPT_USERAGENT,      "curltest/1.0");
    curl_easy_setopt (pCurl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt (pCurl, CURLOPT_CAINFO,         pszCaCertPath);

    AddInLogMessageText ("%s: [%s] GET %s", 0, g_szTask, pszLabel, pszUrl);

    Result = curl_easy_perform (pCurl);

    if (CURLE_OK == Result)
    {
        curl_easy_getinfo (pCurl, CURLINFO_RESPONSE_CODE, &HttpStatus);
        AddInLogMessageText ("%s: [%s] HTTP status: %ld, bytes received: %u", 0, g_szTask, pszLabel, HttpStatus, (unsigned int) Response.Len);

        /* AddInLogMessageText truncates to its own internal line-length
           limit - printf goes straight to the console unbuffered by that
           limit, so the full response body is visible for comparison. */
        // printf ("%s: [%s] Response:\n%s\n", g_szTask, pszLabel, Response.szBuffer);
        // fflush (stdout);
    }
    else
    {
        AddInLogMessageText ("%s: [%s] curl_easy_perform failed: %s", 0, g_szTask, pszLabel, curl_easy_strerror (Result));
    }

    curl_easy_cleanup (pCurl);
}


/* Same as DoCurlGet, but through nnotes.dll's own bundled curl (via the
   g_pfnNotesCurl* function pointers above) instead of the standalone
   libcurl-x64.dll - exercises that instance's actual request path
   directly, not just its version string. */

void DoNotesCurlGet (const char *pszLabel, const char *pszUrl, const char *pszCaCertPath)
{
    CURL              *pCurl    = NULL;
    CURLcode           Result   = CURLE_OK;
    CURLTEST_RESPONSE  Response = {0};

    pCurl = g_pfnNotesCurlEasyInit ();

    if (NULL == pCurl)
    {
        AddInLogMessageText ("%s: [%s] notes curl_easy_init failed", 0, g_szTask, pszLabel);
        return;
    }

    g_pfnNotesCurlEasySetopt (pCurl, CURLOPT_URL,            pszUrl);
    g_pfnNotesCurlEasySetopt (pCurl, CURLOPT_WRITEFUNCTION,  WriteCallback);
    g_pfnNotesCurlEasySetopt (pCurl, CURLOPT_WRITEDATA,      &Response);
    g_pfnNotesCurlEasySetopt (pCurl, CURLOPT_USERAGENT,      "curltest/1.0");
    g_pfnNotesCurlEasySetopt (pCurl, CURLOPT_FOLLOWLOCATION, 1L);
    g_pfnNotesCurlEasySetopt (pCurl, CURLOPT_CAINFO,         pszCaCertPath);

    AddInLogMessageText ("%s: [%s] GET %s", 0, g_szTask, pszLabel, pszUrl);

    Result = g_pfnNotesCurlEasyPerform (pCurl);

    if (CURLE_OK == Result)
    {
        /* curl_easy_getinfo isn't in the verified nnotes.dll export set, so
           no HTTP status code available here - just the byte count. */
        AddInLogMessageText ("%s: [%s] bytes received: %u", 0, g_szTask, pszLabel, (unsigned int) Response.Len);
    }
    else
    {
        AddInLogMessageText ("%s: [%s] notes curl_easy_perform failed: %s", 0, g_szTask, pszLabel, g_pfnNotesCurlEasyStrerror (Result));
    }

    g_pfnNotesCurlEasyCleanup (pCurl);
}


/* Triggers curltest.nsf's "curltest" LotusScript agent (a NotesHTTPRequest
   call) via the documented C-API AgentRun path - this runs Domino's own
   internal curl code (see file header), in this same process, in between
   our own two DoCurlGet() calls. */

void RunDominoAgent (const char *pszDbPath, const char *pszAgentName)
{
    STATUS    error       = NOERROR;
    DBHANDLE  hDb         = NULLHANDLE;
    NOTEID    AgentNoteID = 0;
    HAGENT    hAgent      = NULLHANDLE;
    HAGENTCTX hAgentCtx   = NULLHANDLE;

    error = NSFDbOpen (pszDbPath, &hDb);

    if (error)
    {
        AddInLogMessageText ("%s: NSFDbOpen (%s) failed: %u (0x%04x)", error, g_szTask, pszDbPath, error, error);
        return;
    }

    error = NIFFindDesignNote (hDb, pszAgentName, NOTE_CLASS_FILTER, &AgentNoteID);

    if (error)
    {
        AddInLogMessageText ("%s: NIFFindDesignNote (%s) failed: %u (0x%04x)", error, g_szTask, pszAgentName, error, error);
        NSFDbClose (hDb);
        return;
    }

    error = AgentOpen (hDb, AgentNoteID, &hAgent);

    if (error)
    {
        AddInLogMessageText ("%s: AgentOpen failed: %u (0x%04x)", error, g_szTask, error, error);
        NSFDbClose (hDb);
        return;
    }

    error = AgentCreateRunContext (hAgent, NULL, 0, &hAgentCtx);

    if (error)
    {
        AddInLogMessageText ("%s: AgentCreateRunContext failed: %u (0x%04x)", error, g_szTask, error, error);
        AgentClose (hAgent);
        NSFDbClose (hDb);
        return;
    }

    AddInLogMessageText ("%s: Running agent %s in %s", 0, g_szTask, pszAgentName, pszDbPath);

    error = AgentRun (hAgent, hAgentCtx, NULLHANDLE, 0);

    if (error)
        AddInLogMessageText ("%s: AgentRun failed: %u (0x%04x)", error, g_szTask, error, error);
    else
        AddInLogMessageText ("%s: Agent run completed", 0, g_szTask);

    AgentDestroyRunContext (hAgentCtx);
    AgentClose (hAgent);
    NSFDbClose (hDb);
}


STATUS LNPUBLIC AddInMain (HMODULE hModule, int argc, char far *argv[])
{
    HMODULE hMod            = NULLHANDLE;
    DHANDLE hOldStatusLine  = NULLHANDLE;
    DHANDLE hStatusLineDesc = NULLHANDLE;
    char    szCaCertPath[MAXPATH + 1] = {0};

    (void) hModule;
    (void) argc;
    (void) argv;

    AddInQueryDefaults    (&hMod, &hOldStatusLine);
    AddInDeleteStatusLine (hOldStatusLine);

    hStatusLineDesc = AddInCreateStatusLine (g_szTaskLong);
    AddInSetDefaults (hMod, hStatusLineDesc);

    AddInLogMessageText ("%s: Starting (%s)", 0, g_szTask, g_szTaskLong);

    BuildCaCertPath (sizeof (szCaCertPath), szCaCertPath);

    if (!LoadNotesCurlFunctions ())
    {
        AddInLogMessageText ("%s: Terminating - could not load nnotes.dll curl functions", 0, g_szTask);
        return ERR_MISC_INVALID_ARGS;
    }

    curl_global_init (CURL_GLOBAL_DEFAULT);

    AddInLogMessageText ("%s: curl standalone : %s", 0, g_szTask, curl_version ());
    AddInLogMessageText ("%s: curl nnotes.dll : %s", 0, g_szTask, g_pfnNotesCurlVersion ());

    /* Full OpenSSL version info, same fields/calls as test_openssl.cpp's
       print_version() in the main nashcom-build-artifacts pipeline.
       OpenSSL_version() already returns self-labeled strings for the last
       four ("built on: ...", "platform: ...", etc.) - no extra label added
       here to avoid saying it twice. */

    AddInLogMessageText ("%s: OpenSSL compile Version: %s", 0, g_szTask, OPENSSL_VERSION_TEXT);
    AddInLogMessageText ("%s: OpenSSL runtime Version: %s", 0, g_szTask, OpenSSL_version (OPENSSL_VERSION));
    AddInLogMessageText ("%s: OpenSSL %s", 0, g_szTask, OpenSSL_version (OPENSSL_BUILT_ON));
    AddInLogMessageText ("%s: OpenSSL %s", 0, g_szTask, OpenSSL_version (OPENSSL_PLATFORM));
    AddInLogMessageText ("%s: OpenSSL %s", 0, g_szTask, OpenSSL_version (OPENSSL_CFLAGS));
    AddInLogMessageText ("%s: OpenSSL %s", 0, g_szTask, OpenSSL_version (OPENSSL_DIR));

    /* Settle empirically whether these are really two different curl
       instances, or the same code resolved twice - compare the actual
       function addresses rather than trusting the version strings alone.
       Format the addresses ourselves via snprintf (real libc, handles %p
       correctly) rather than passing %p straight to AddInLogMessageText,
       which has its own limited, non-standard format specifier set. */
    {
        char szCurlAddr[32]      = {0};
        char szNotesCurlAddr[32] = {0};

        snprintf (szCurlAddr,      sizeof (szCurlAddr),      "%p", (void *) curl_version);
        snprintf (szNotesCurlAddr, sizeof (szNotesCurlAddr), "%p", (void *) g_pfnNotesCurlVersion);

        AddInLogMessageText ("%s: curl_version address: %s, notes_curl_version address: %s (%s)",
                              0, g_szTask, szCurlAddr, szNotesCurlAddr,
                              (0 == strcmp (szCurlAddr, szNotesCurlAddr)) ? "SAME" : "DIFFERENT");
    }

    DoNotesCurlGet ("notes-curl", CURLTEST_URL, szCaCertPath);

    DoCurlGet ("before-agent", CURLTEST_URL, szCaCertPath);

    RunDominoAgent (CURLTEST_AGENT_DB, CURLTEST_AGENT_NAME);

    DoCurlGet ("after-agent", CURLTEST_URL, szCaCertPath);

    curl_global_cleanup ();

    AddInLogMessageText ("%s: Standalone libcurl global cleanup completed", 0, g_szTask);

    /* Flipped test: does OUR OWN curl_global_cleanup() (potentially touching
       process-wide shared state like WSAStartup/WSACleanup's reference
       count, even though curl's own globals are otherwise independent
       between the two separate DLLs) break Domino's own curl usage run
       afterward? Complements the before/after test above, which checked
       the other direction. */

    RunDominoAgent (CURLTEST_AGENT_DB, CURLTEST_AGENT_NAME);
    AddInLogMessageText ("%s: Terminating", 0, g_szTask);

    return NOERROR;
}
