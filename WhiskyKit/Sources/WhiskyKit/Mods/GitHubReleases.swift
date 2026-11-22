//
//  GitHubReleases.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

public struct GitHubRelease: Decodable, Sendable, Hashable {
    public struct Asset: Decodable, Sendable, Hashable {
        public let name: String
        public let size: Int
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey { // swiftlint:disable:this nesting
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let publishedAt: Date?
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case prerelease, assets
    }

    /// Whether the release is older than about six months.
    public var isStale: Bool {
        guard let publishedAt else { return false }
        return Date().timeIntervalSince(publishedAt) > 60 * 60 * 24 * 182
    }
}

public enum GitHubError: LocalizedError {
    case badResponse(status: Int, repo: String)
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .badResponse(let status, let repo):
            return "GitHub returned \(status) for \(repo)."
        case .rateLimited:
            return "GitHub's hourly limit was reached. Try again later."
        }
    }
}

/// Reads public release and README data from GitHub.
public enum GitHubReleases {
    static let api = URL(string: "https://api.github.com")!

    public static func latestRelease(repo: String, session: URLSession = .shared) async throws -> GitHubRelease {
        let data = try await get(api.appending(path: "repos/\(repo)/releases/latest"), repo: repo, session: session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// The repository's README as plain text, or `nil` when it has none.
    public static func readme(repo: String, session: URLSession = .shared) async throws -> String? {
        do {
            let data = try await get(
                api.appending(path: "repos/\(repo)/readme"), repo: repo,
                accept: "application/vnd.github.raw", session: session
            )
            return String(data: data, encoding: .utf8)
        } catch GitHubError.badResponse(status: 404, _) {
            return nil
        }
    }

    private static func get(
        _ url: URL, repo: String, accept: String = "application/vnd.github+json", session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("BetterWhisky", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 429 { throw GitHubError.rateLimited }
        guard (200..<300).contains(status) else { throw GitHubError.badResponse(status: status, repo: repo) }
        return data
    }
}
