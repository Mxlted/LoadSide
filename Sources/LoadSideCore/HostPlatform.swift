// This restriction applies to LoadSide itself, never to architectures inside user archives.
#if !os(macOS) || !arch(arm64)
    #error("LoadSide supports only native arm64 macOS builds. Keep user-archive Mach-O architecture handling independent.")
#endif
