# Windows 64-bit version using
# Microsoft Visual Studio 2017
#
# Standalone libcurl test - links against a real, separately-deployed
# libcurl-x64.dll, NOT the copy bundled inside nnotes.dll. libcurl-x64.dll
# must be reachable at runtime (same directory as the exe, or on PATH) -
# unlike linking against nnotes.dll's bundled copy, there is no free ride
# here; that is exactly the tradeoff this test is exploring. Override
# CURL_SDK_DIR to wherever that SDK (an include/ dir plus the .lib/.dll)
# is deployed on your own machine, e.g.:
#   nmake -f mswin64.mak CURL_SDK_DIR=X:\curl

PROGRAM=curltest

NODEBUG=1

# Link command

n$(PROGRAM).exe: $(PROGRAM).obj libcurl-x64.lib
	link /SUBSYSTEM:CONSOLE $(PROGRAM).obj notes0.obj notesai0.obj notes.lib libcurl-x64.lib msvcrt.lib user32.lib /PDB:$*.pdb /DEBUG /PDBSTRIPPED:$*_small.pdb -out:$@
	del $*.pdb $*.sym
	rename $*_small.pdb $*.pdb

# Compile command

$(PROGRAM).obj: $(PROGRAM).cpp
	cl -nologo -c -D_MT -MT /Zi /Ot /O2 /Ob2 /Oy- -Gd /Gy /GF /Gs4096 /GS- /favor:INTEL64 /EHsc /Zc:wchar_t- /DWINVER=0x0602 -Zl -W1 -DNT -DW32 -DW -DW64 -DND64 -D_AMD64_ -DDTRACE -D_CRT_SECURE_NO_WARNINGS -DND64SERVER -DPRODUCTION_VERSION /DUSE_WIN32_IDN -I"$(CURL_SDK_DIR)\include" $*.cpp

# Import lib for the real, standalone libcurl-x64.dll (from CURL_SDK_DIR).
# This is the vendor's own .def - copied locally and given a LIBRARY
# statement (the vendor's copy doesn't have one, which makes lib.exe
# embed the wrong DLL name without it).

libcurl-x64.lib: libcurl-x64.def
	lib /DEF:libcurl-x64.def /MACHINE:X64 /OUT:libcurl-x64.lib

all:
	n$(PROGRAM).exe

clean:
	del *.obj *.pdb *.exe *.dll *.ilk *.sym *.map *.lib *.exp
