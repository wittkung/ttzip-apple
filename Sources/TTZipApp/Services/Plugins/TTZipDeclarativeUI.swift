// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

public struct TTZipDeclarativeUI {
    @MainActor
    public static func render(json: [String: Any]) -> AnyView {
        guard let type = json["type"] as? String else {
            return AnyView(errorPlaceholder("Missing UI type"))
        }

        switch type {
        case "vstack":
            return AnyView(
                VStack {
                    renderChildren(json["children"] as? [[String: Any]] ?? [])
                }
                .applyModifiers(from: json)
            )
        case "hstack":
            return AnyView(
                HStack {
                    renderChildren(json["children"] as? [[String: Any]] ?? [])
                }
                .applyModifiers(from: json)
            )
        case "zstack":
            return AnyView(
                ZStack {
                    renderChildren(json["children"] as? [[String: Any]] ?? [])
                }
                .applyModifiers(from: json)
            )
        case "scroll":
            return AnyView(
                ScrollView {
                    renderChildren(json["children"] as? [[String: Any]] ?? [])
                }
                .applyModifiers(from: json)
            )
        case "text":
            return AnyView(TextNode(json: json).applyModifiers(from: json))
        case "button":
            return AnyView(ButtonNode(json: json).applyModifiers(from: json))
        case "image":
            return AnyView(ImageNode(json: json).applyModifiers(from: json))
        case "spacer":
            return AnyView(Spacer().applyModifiers(from: json))
        case "divider":
            return AnyView(Divider().applyModifiers(from: json))
        case "textfield":
            return AnyView(TextFieldNode(json: json).applyModifiers(from: json))
        default:
            return AnyView(errorPlaceholder("Unknown UI type: \(type)"))
        }
    }
    
    @MainActor
    @ViewBuilder
    private static func renderChildren(_ children: [[String: Any]]) -> some View {
        ForEach(0..<children.count, id: \.self) { index in
            render(json: children[index])
        }
    }
    
    @MainActor
    private static func errorPlaceholder(_ message: String) -> some View {
        Text("UI Error: \(message)")
            .foregroundColor(.red)
            .padding()
            .background(Color.yellow.opacity(0.3))
            .cornerRadius(8)
    }
}

// Nodes
private struct TextNode: View {
    let json: [String: Any]
    
    var body: some View {
        let text = json["text"] as? String ?? ""
        var view: Text = Text(text)
        
        if let colorStr = json["color"] as? String {
            view = view.foregroundColor(parseColor(colorStr))
        }
        
        if let weightStr = json["weight"] as? String {
            view = view.fontWeight(parseWeight(weightStr))
        }
        
        if let fontStr = json["font"] as? String {
            view = view.font(parseFont(fontStr))
        }
        
        return view
    }
}

private struct ButtonNode: View {
    let json: [String: Any]
    
    var body: some View {
        let title = json["title"] as? String ?? "Button"
        let callbackID = json["onTap"] as? String
        
        Button(title) {
            if let id = callbackID {
                NotificationCenter.default.post(name: NSNotification.Name("TTZipJSAction"), object: nil, userInfo: ["action": id])
            }
        }
    }
}

private struct ImageNode: View {
    let json: [String: Any]
    
    var body: some View {
        let systemName = json["systemName"] as? String ?? "questionmark"
        Image(systemName: systemName)
    }
}

private struct TextFieldNode: View {
    let json: [String: Any]
    @State private var text: String = ""
    
    var body: some View {
        let placeholder = json["placeholder"] as? String ?? ""
        let bindKey = json["bind"] as? String
        
        TextField(placeholder, text: $text)
            .onChange(of: text) { _, newValue in
                if let key = bindKey {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipJSAction_Bind"), object: nil, userInfo: ["key": key, "value": newValue])
                }
            }
            .onAppear {
                if let initial = json["value"] as? String {
                    self.text = initial
                }
            }
    }
}

// Modifiers & Parsers
@MainActor
private extension View {
    func applyModifiers(from json: [String: Any]) -> AnyView {
        var view: AnyView = AnyView(self)
        
        if let padding = json["padding"] as? CGFloat {
            view = AnyView(view.padding(padding))
        } else if let padding = json["padding"] as? Int {
            view = AnyView(view.padding(CGFloat(padding)))
        } else if let padding = json["padding"] as? Double {
            view = AnyView(view.padding(CGFloat(padding)))
        }
        
        if let frame = json["frame"] as? [String: Any] {
            let width = (frame["width"] as? NSNumber).map { CGFloat($0.floatValue) }
            let height = (frame["height"] as? NSNumber).map { CGFloat($0.floatValue) }
            view = AnyView(view.frame(width: width, height: height))
        }
        
        if let bgStr = json["background"] as? String {
            view = AnyView(view.background(parseColor(bgStr)))
        }
        
        if let radius = (json["cornerRadius"] as? NSNumber).map({ CGFloat($0.floatValue) }) {
            view = AnyView(view.cornerRadius(radius))
        }
        
        return view
    }
}

private func parseColor(_ hex: String) -> Color {
    switch hex {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "yellow": return .yellow
    case "gray": return .gray
    case "black": return .black
    case "white": return .white
    case "primary": return .primary
    case "secondary": return .secondary
    default: return .clear
    }
}

private func parseWeight(_ weight: String) -> Font.Weight {
    switch weight {
    case "bold": return .bold
    case "semibold": return .semibold
    case "light": return .light
    case "regular": return .regular
    default: return .regular
    }
}

private func parseFont(_ font: String) -> Font {
    switch font {
    case "title": return .title
    case "headline": return .headline
    case "subheadline": return .subheadline
    case "body": return .body
    case "caption": return .caption
    default: return .body
    }
}
