//
//  AboutView.swift
//  Tristimulator
//
//  Created by Alex Fry on 2/3/2026.
//

import SwiftUI

struct AboutView: View {
    private let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }()
    private let buildNumber: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }()
    private let copyright: String = {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }()

    var body: some View {
        VStack(spacing: 12) {
            // App icon + name + version
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Tristimulator")
                .font(.system(size: 20, weight: .bold))

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !copyright.isEmpty {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Tristimulator code is MIT. Third-party licences are in the app’s ThirdPartyNotices folder.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.horizontal, 20)

            // Library icons
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Image("openimageio-icon-gradient")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                    Text("OpenImageIO 3.1.14.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Image("opencolorio-icon-color")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                    Text("OpenColorIO 2.5.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 320)
        .fixedSize()
    }
}
#Preview {
    AboutView()
}

