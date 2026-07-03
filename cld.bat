@echo off
rem ---------------------------------------------------------------------------
rem  cld.bat - DEBUG build of lal4s. Same clean W^X flags as cl.bat, plus:
rem    ml   /Zi /Zd   CodeView debug info in the .obj
rem    link /debug    emit lal4s.pdb so the SEH crash dump's Eip / addresses
rem                   resolve to source in cdb/windbg (pair with lal4s.map).
rem  Still W^X: NO /section:.text,ERW, NO /section:_STACK,ERW, no RWX.
rem  Use cl.bat for the release/clean (no-pdb, sign-able) build.
rem ---------------------------------------------------------------------------
ml /coff /c /nologo /Zi /Zd /Fm /Fl lal4s.asm
if errorlevel 1 goto end
rc /c 850 /v resource.rc
if errorlevel 1 goto end
cvtres /machine:ix86 resource.res
link /SUBSYSTEM:WINDOWS /MACHINE:X86 /FIXED /entry:_start /STACK:1048576 /debug /MAP /MAPINFO:EXPORTS /LIBPATH:. lal4s.obj resource.obj
if errorlevel 1 goto end
echo #### SUCCESS (debug) ####
:end
