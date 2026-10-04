import Foundation

/// Summary of metadata decoded from an audio file.
///
/// All fields are populated defensively; missing pieces are `nil` rather
/// than `0` so the UI can distinguish "absent" from "zero". The model is
/// intentionally value-typed so it is trivially copyable across actor
/// boundaries (Core Audio decoder callbacks, Quick Look previewing
/// controller).
public struct AudioMetadata: Equatable, Sendable {
    public var fileName: String
    public var fileSizeBytes: Int64
    public var containerUTType: String?
    public var containerDescription: String?
    public var codec: String?
    public var durationSeconds: Double?
    public var sampleRateHz: Double?
    public var bitDepth: Int?
    public var channels: Int?
    public var channelLayoutName: String?
    public var bitRate: Int?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var bwfTimeReferenceSamples: UInt64?
    public var bwfTimeReferenceSeconds: Double?
    public var iXMLProject: String?
    public var iXMLScene: String?
    public var iXMLTape: String?
    public var iXMLTrack: String?
    public var iXMLNotes: String?
    public var hasArtwork: Bool
    /// Bounded (≤ 4 MiB) embedded artwork bytes; nil when absent.
    public var artworkData: Data?
    /// Decoded bext chunk (originator, dates, version…).
    public var bwf: BWFChunk?
    /// Speaker label per channel (file layout, else conventional order).
    public var channelLabels: [String] = []
    /// ADM BWF (ITU-R BS.2076 `axml` + `chna`): an object-based master such as a
    /// Dolby Atmos ADM export. `admTrackCount` is the chna track count.
    public var isADM = false
    public var admTrackCount: Int?
    /// A `dbmd` chunk: Dolby metadata travels with the file.
    public var hasDolbyMetadata = false
    public var isRF64 = false
    /// Non-fatal inspection problems, surfaced in the UI instead of hiding the failure.
    public var warnings: [String] = []

    public init(
        fileName: String,
        fileSizeBytes: Int64,
        containerUTType: String? = nil,
        containerDescription: String? = nil,
        codec: String? = nil,
        durationSeconds: Double? = nil,
        sampleRateHz: Double? = nil,
        bitDepth: Int? = nil,
        channels: Int? = nil,
        channelLayoutName: String? = nil,
        bitRate: Int? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        bwfTimeReferenceSamples: UInt64? = nil,
        bwfTimeReferenceSeconds: Double? = nil,
        iXMLProject: String? = nil,
        iXMLScene: String? = nil,
        iXMLTape: String? = nil,
        iXMLTrack: String? = nil,
        iXMLNotes: String? = nil,
        hasArtwork: Bool = false
    ) {
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.containerUTType = containerUTType
        self.containerDescription = containerDescription
        self.codec = codec
        self.durationSeconds = durationSeconds
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.channels = channels
        self.channelLayoutName = channelLayoutName
        self.bitRate = bitRate
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.bwfTimeReferenceSamples = bwfTimeReferenceSamples
        self.bwfTimeReferenceSeconds = bwfTimeReferenceSeconds
        self.iXMLProject = iXMLProject
        self.iXMLScene = iXMLScene
        self.iXMLTape = iXMLTape
        self.iXMLTrack = iXMLTrack
        self.iXMLNotes = iXMLNotes
        self.hasArtwork = hasArtwork
    }

    public static func == (lhs: AudioMetadata, rhs: AudioMetadata) -> Bool {
        return lhs.fileName == rhs.fileName
            && lhs.fileSizeBytes == rhs.fileSizeBytes
            && lhs.containerUTType == rhs.containerUTType
            && lhs.containerDescription == rhs.containerDescription
            && lhs.codec == rhs.codec
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.sampleRateHz == rhs.sampleRateHz
            && lhs.bitDepth == rhs.bitDepth
            && lhs.channels == rhs.channels
            && lhs.channelLayoutName == rhs.channelLayoutName
            && lhs.bitRate == rhs.bitRate
            && lhs.creationDate == rhs.creationDate
            && lhs.modificationDate == rhs.modificationDate
            && lhs.bwfTimeReferenceSamples == rhs.bwfTimeReferenceSamples
            && lhs.bwfTimeReferenceSeconds == rhs.bwfTimeReferenceSeconds
            && lhs.iXMLProject == rhs.iXMLProject
            && lhs.iXMLScene == rhs.iXMLScene
            && lhs.iXMLTape == rhs.iXMLTape
            && lhs.iXMLTrack == rhs.iXMLTrack
            && lhs.iXMLNotes == rhs.iXMLNotes
            && lhs.hasArtwork == rhs.hasArtwork
            && lhs.channelLabels == rhs.channelLabels
            && lhs.isADM == rhs.isADM
            && lhs.admTrackCount == rhs.admTrackCount
            && lhs.hasDolbyMetadata == rhs.hasDolbyMetadata
            && lhs.isRF64 == rhs.isRF64
    }
}
