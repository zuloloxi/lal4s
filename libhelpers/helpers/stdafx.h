// stdafx.h : include file for standard system include files,
// or project specific include files that are used frequently, but
// are changed infrequently
//

#pragma once

// Modify the following defines if you have to target a platform prior to the ones specified below.
// Refer to MSDN for the latest info on corresponding values for different platforms.
#ifndef WINVER				// 0x0501→0x0601 for UIA; →0x0A00 for WinHTTP
#define WINVER 0x0A00		//   WebSocket (CDP client). Win10 target.
#endif

#ifndef _WIN32_WINNT		// WinHttpWebSocket* needs >=0x0602 (Win8);
#define _WIN32_WINNT 0x0A00	//   use 0x0A00 (Win10) to match the OS.
#endif

#ifndef _WIN32_WINDOWS		// Allow use of features specific to Windows 98 or later.
#define _WIN32_WINDOWS 0x0410 // Change this to the appropriate value to target Windows Me or later.
#endif

#ifndef _WIN32_IE			// Allow use of features specific to IE 6.0 or later.
#define _WIN32_IE 0x0600	// Change this to the appropriate value to target other versions of IE.
#endif

#define WIN32_LEAN_AND_MEAN		// Exclude rarely-used stuff from Windows headers
// Windows Header Files:
#include <windows.h>
#include <stdio.h>
#include <tchar.h>

// COM + UI Automation prerequisites must come BEFORE UIAutomation.h.
// Placed in stdafx so the PCH has the full COM context.
#include <ole2.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <wchar.h>
