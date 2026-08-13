import AppKit
import Foundation
import SwiftUI

struct CodeFileIconDescriptor: Equatable, Sendable {
    let resourceName: String
    let fallbackSystemName: String
}

enum CodeFileIconResolver {
    static let defaultResourceName = "default_file"

    private static let specialNames: [String: String] = [
        ".gitattributes": "file_type_git",
        ".gitignore": "file_type_git",
        ".gitmodules": "file_type_git",
        ".nvmrc": "file_type_node",
        "cargo.lock": "file_type_rust",
        "cargo.toml": "file_type_rust",
        "composer.json": "file_type_php3",
        "composer.lock": "file_type_php3",
        "gemfile": "file_type_ruby",
        "gemfile.lock": "file_type_ruby",
        "go.mod": "file_type_go_gopher",
        "go.sum": "file_type_go_gopher",
        "npm-shrinkwrap.json": "file_type_npm",
        "package-lock.json": "file_type_npm",
        "package.json": "file_type_node",
        "package.swift": "file_type_swift",
        "pnpm-lock.yaml": "file_type_pnpm",
        "yarn.lock": "file_type_yarn"
    ]

    private static let compoundExtensions: [String: String] = [
        "d.ts": "file_type_typescript_official",
        "tar.bz2": "file_type_zip",
        "tar.gz": "file_type_zip",
        "tar.xz": "file_type_zip"
    ]

    private static let extensions: [String: String] = [
        "7z": "file_type_zip",
        "bash": "file_type_shell",
        "bmp": "file_type_image",
        "bz2": "file_type_zip",
        "c": "file_type_c",
        "cc": "file_type_cpp3",
        "cjs": "file_type_js_official",
        "cpp": "file_type_cpp3",
        "cs": "file_type_csharp2",
        "css": "file_type_css",
        "cts": "file_type_typescript_official",
        "cxx": "file_type_cpp3",
        "fish": "file_type_shell",
        "gif": "file_type_image",
        "go": "file_type_go_gopher",
        "gz": "file_type_zip",
        "h": "file_type_c",
        "heic": "file_type_image",
        "htm": "file_type_html",
        "html": "file_type_html",
        "hpp": "file_type_cpp3",
        "hxx": "file_type_cpp3",
        "java": "file_type_java",
        "jpeg": "file_type_image",
        "jpg": "file_type_image",
        "js": "file_type_js_official",
        "json": "file_type_json_official",
        "jsonc": "file_type_json_official",
        "jsx": "file_type_reactjs",
        "kt": "file_type_kotlin",
        "kts": "file_type_kotlin",
        "less": "file_type_css",
        "md": "file_type_markdown",
        "mdx": "file_type_markdown",
        "mjs": "file_type_js_official",
        "mts": "file_type_typescript_official",
        "php": "file_type_php3",
        "plist": "file_type_xml",
        "png": "file_type_image",
        "py": "file_type_python",
        "pyw": "file_type_python",
        "rb": "file_type_ruby",
        "rs": "file_type_rust",
        "sass": "file_type_css",
        "scss": "file_type_css",
        "sh": "file_type_shell",
        "sql": "file_type_sql",
        "svelte": "file_type_svelte",
        "svg": "file_type_image",
        "swift": "file_type_swift",
        "tar": "file_type_zip",
        "tgz": "file_type_zip",
        "toml": "file_type_toml",
        "ts": "file_type_typescript_official",
        "tsx": "file_type_reactjs",
        "vue": "file_type_vue",
        "webp": "file_type_image",
        "xml": "file_type_xml",
        "xz": "file_type_zip",
        "yaml": "file_type_yaml",
        "yml": "file_type_yaml",
        "zip": "file_type_zip",
        "zsh": "file_type_shell"
    ]

    static var allResourceNames: Set<String> {
        Set(specialNames.values)
            .union(compoundExtensions.values)
            .union(extensions.values)
            .union([defaultResourceName, "file_type_docker2"])
    }

    static func descriptor(for path: String) -> CodeFileIconDescriptor {
        let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()

        if filename == "dockerfile" || filename.hasPrefix("dockerfile.") {
            return descriptor(resourceName: "file_type_docker2")
        }
        if filename == "readme" || filename.hasPrefix("readme.")
            || filename == "changelog" || filename.hasPrefix("changelog.") {
            return descriptor(resourceName: "file_type_markdown")
        }
        if let resourceName = specialNames[filename] {
            return descriptor(resourceName: resourceName)
        }
        if let match = compoundExtensions.first(where: { filename.hasSuffix(".\($0.key)") }) {
            return descriptor(resourceName: match.value, fileExtension: match.key)
        }

        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if let resourceName = extensions[fileExtension] {
            return descriptor(resourceName: resourceName, fileExtension: fileExtension)
        }
        return descriptor(resourceName: defaultResourceName)
    }

    private static func descriptor(
        resourceName: String,
        fileExtension: String = ""
    ) -> CodeFileIconDescriptor {
        let fallbackSystemName: String
        if ["bmp", "gif", "heic", "jpeg", "jpg", "png", "svg", "webp"].contains(fileExtension) {
            fallbackSystemName = "photo"
        } else if ["7z", "bz2", "gz", "tar", "tar.bz2", "tar.gz", "tar.xz", "tgz", "xz", "zip"].contains(fileExtension) {
            fallbackSystemName = "archivebox"
        } else {
            fallbackSystemName = "doc"
        }
        return CodeFileIconDescriptor(
            resourceName: resourceName,
            fallbackSystemName: fallbackSystemName
        )
    }
}

struct CodeFileIcon: View {
    let path: String
    var size: CGFloat = 18

    private var descriptor: CodeFileIconDescriptor {
        CodeFileIconResolver.descriptor(for: path)
    }

    var body: some View {
        Group {
            if let image = bundledImage(named: descriptor.resourceName) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: descriptor.fallbackSystemName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func bundledImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "FileIcons"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct CodeChangedFileList: View {
    let files: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(files.enumerated()), id: \.offset) { _, path in
                HStack(alignment: .top, spacing: 7) {
                    CodeFileIcon(path: path, size: 16)
                        .padding(.top, 1)
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(path)
            }
        }
    }
}
