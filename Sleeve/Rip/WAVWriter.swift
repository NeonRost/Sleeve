//
//  WAVWriter.swift
//  Sleeve
//
//  Gerippte Spuren landen zunächst als WAV. Von dort übernimmt die bestehende
//  Konverter-Pipeline (Spec §5) — der Ripper muss keine Codecs kennen.
//
//  CDDA ist 16 Bit, 44100 Hz, Stereo, little-endian. Genau das schreibt ein
//  kanonischer 44-Byte-WAV-Kopf, ohne jede Sonderbehandlung.
//

import Foundation

enum WAVWriter {
    static let sampleRate = 44100
    static let channels = 2
    static let bitsPerSample = 16

    static func header(forPCMByteCount byteCount: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var data = Data(capacity: 44)
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + byteCount)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)              // Länge des Formatblocks
        u16(1)               // 1 = unkomprimiertes PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(byteCount)
        return data
    }

    /// Schreibt die Datei in einem Zug. Eine CD-Spur ist selten größer als
    /// 100 MB, das rechtfertigt kein stückweises Schreiben.
    static func write(pcm: Data, to url: URL) throws {
        var file = header(forPCMByteCount: pcm.count)
        file.append(pcm)
        try file.write(to: url, options: .atomic)
    }
}
