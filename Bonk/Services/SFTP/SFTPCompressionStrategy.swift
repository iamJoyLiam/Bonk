//
//  SFTPCompressionStrategy.swift
// Bonk —
//
//  
// • zip/gz/mp4/dmg/iso/video
// • log/json/sql/csv/xml/txt
// • SSH  aes128-gcm@openssh.com > chacha20-poly1305 > aes128-ctr

import Foundation

enum SFTPCompressionStrategy {
    // / /，
    static let noCompressExtensions: Set<String> = [
        "zip", "gz", "bz2", "xz", "7z", "rar",
        "mp4", "mov", "avi", "mkv", "mp3", "flac", "wav",
        "jpg", "jpeg", "png", "heic", "webp", "gif",
        "dmg", "iso", "img", "pkg", "pdf",
        "mpg", "mpeg", "webm", "ogg",
        "parquet", "avro", "zst", "lz4"
    ]

    static let compressExtensions: Set<String> = [
        "log", "txt", "json", "sql", "csv", "xml", "yaml", "yml",
        "md", "html", "css", "js", "ts", "swift", "py", "c", "h", "cpp",
        "sh", "conf", "ini", "toml", "properties"
    ]

    static func shouldCompress(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty { return false }
        if noCompressExtensions.contains(ext) { return false }
        if compressExtensions.contains(ext) { return true }
        //  
        return false
    }

    static func shouldCompress(url: URL) -> Bool {
        shouldCompress(fileName: url.lastPathComponent)
    }

    // / OpenSSH Ciphers GCM
    static let preferredCiphers = "aes128-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr"
    static let preferredMACs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
}
