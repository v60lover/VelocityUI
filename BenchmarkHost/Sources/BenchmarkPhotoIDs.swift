// BenchmarkPhotoIDs.swift

/// Fixed Unsplash photo IDs used by `BenchmarkDataset` and `StreamDataset` in place of
/// picsum.photos, which went down (503s on every request as of 2026-08-31). Each ID is
/// the `photo-<id>` segment of `images.unsplash.com/photo-<id>`, verified to resolve.
/// `BenchmarkDataset.generate` cycles through this table by `i % table.count`, same way
/// it cycles `PrecomputedBlurHashes.table`.
enum BenchmarkPhotoIDs {
    static let table: [String] = [
        "1500648767791-00dcc994a43e",
        "1506905925346-21bda4d32df4",
        "1441974231531-c6227db76b6e",
        "1472214103451-9374bd1c798e",
        "1447752875215-b2761acb3c5d",
        "1506744038136-46273834b3fb",
        "1493246507139-91e8fad9978e",
        "1441986300917-64674bd600d8",
        "1522202176988-66273c2fd55f",
        "1470813740244-df37b8c1edcb",
        "1418065460487-3e41a6c84dc5",
        "1501854140801-50d01698950b",
        "1499346030926-9a72daac6c63",
        "1476514525535-07fb3b4ae5f1",
        "1416339306562-f3d12fefd36f",
        "1518791841217-8f162f1e1131",
        "1470252649378-9c29740c9fa8",
        "1439853949127-fa647821eba0"
    ]
}
