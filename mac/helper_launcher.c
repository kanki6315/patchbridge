// Isolated embedded CPython. No PATH lookup, user site, PYTHONPATH, or working-directory imports.
#include <Python.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    int verify_usb = argc == 3 && strcmp(argv[1], "--verify-usb-fixtures") == 0;
    int captured = argc == 3 && strcmp(argv[1], "--captured-read-only") == 0;
    if (argc != 1 && !verify_usb && !captured) { fputs("Only offline fixture verification or captured read-only mode is supported. Live USB is disabled.\n", stderr); return 64; }
    char executable[PATH_MAX], resolved[PATH_MAX], path[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) || !realpath(executable, resolved)) return 70;
    char *slash = strrchr(resolved, '/');
    if (!slash) return 70;
    *slash = 0; // Contents/MacOS
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.module_search_paths_set = 1;
    PyStatus status;
#define CHECK(call) do { status = (call); if (PyStatus_Exception(status)) goto fail; } while (0)
    CHECK(PyConfig_SetBytesString(&config, &config.program_name, executable));
    snprintf(path, sizeof(path), "%s/../Resources/Python", resolved);
    CHECK(PyConfig_SetBytesString(&config, &config.home, path));
    const char *suffixes[] = {"/../Resources/Python/lib", "/../Resources/Python/lib-dynload", "/../Resources/Helper"};
    for (int i = 0; i < 3; i++) {
        snprintf(path, sizeof(path), "%s%s", resolved, suffixes[i]);
        wchar_t *wide = Py_DecodeLocale(path, NULL);
        if (!wide) { PyConfig_Clear(&config); return 70; }
        status = PyWideStringList_Append(&config.module_search_paths, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) goto fail;
    }
    char *python_argv[] = {"patchbridge-helper", "--adapter", "simulated"};
    char *check_argv[] = {"patchbridge-helper", verify_usb ? argv[2] : ""};
    char *captured_argv[] = {"patchbridge-helper", "--adapter", "captured-read-only", "--fixture", captured ? argv[2] : ""};
    config.parse_argv = 0;
    CHECK(PyConfig_SetBytesArgv(&config, captured ? 5 : (verify_usb ? 2 : 3), captured ? captured_argv : (verify_usb ? check_argv : python_argv)));
    CHECK(PyConfig_SetString(&config, &config.run_module, verify_usb ? L"patchbridge.offline_usb_check" : L"patchbridge.helper"));
    CHECK(Py_InitializeFromConfig(&config));
    PyConfig_Clear(&config);
    return Py_RunMain();
fail:
    PyConfig_Clear(&config);
    Py_ExitStatusException(status);
}
