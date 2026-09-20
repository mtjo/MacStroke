// The appex binary's real entry point is _NSExtensionMain, forced via a
// linker flag in Package.swift; this stub only satisfies SwiftPM's
// executable-target requirement.

@main
struct ExtensionMain {
    static func main() {}
}
