@echo off
rem ---------------------------------------------------------------------------
rem  lal4s build - CLEAN W^X profile (the whole point vs cf22):
rem    * no /section:.text,ERW   (no writable code section)
rem    * no /section:_STACK,ERW  (no executable stack)
rem    * no runtime codegen / RWX VirtualAlloc (no Forth JIT)
rem    -> only the LL keyboard hook + SendInput remain as AV signal; sign to
rem       clear reputation. See EXTRACTION_PLAN.md.
rem
rem  Toolchain (ml/rc/cvtres/link, MASM 6) must be on PATH. Import libs
rem  (kernel32/gdi32/user32/shell32.lib) are kept locally in this folder, so
rem  /LIBPATH:. points the linker here (self-contained; no cf22 dependency).
rem ---------------------------------------------------------------------------
ml /coff /c /nologo /Fm /Fl lal4s.asm
if errorlevel 1 goto end
rc /c 850 /v resource.rc
if errorlevel 1 goto end
cvtres /machine:ix86 resource.res
link /SUBSYSTEM:WINDOWS /MACHINE:X86 /entry:_start /STACK:1048576 /MAP /MAPINFO:EXPORTS /LIBPATH:. lal4s.obj resource.obj
if errorlevel 1 goto end
echo #### SUCCESS ####
:end
