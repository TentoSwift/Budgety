//
//  SheetSymbols.swift
//  Budgety
//
//  シート (= グループ・予算) のアイコン選択肢。
//  カテゴリの SF Symbol とは別に、シートの性格に合うものをキュレーション。
//  Premium ユーザーは Premium 限定の追加カタログも選択可。
//

import Foundation

enum SheetSymbols {
    /// 無料ユーザーが選べる基本アイコン (シートの基本的な性格を表現)
    static let freeOptions: [String] = [
        // 人・グループ系
        "person.2.fill",
        "person.3.fill",
        "person.crop.circle.fill",
        "heart.fill",
        // 家・建物
        "house.fill",
        "building.2.fill",
        "bed.double.fill",
        "fork.knife",
        // 旅行・移動
        "airplane",
        "car.fill",
        "tram.fill",
        "map.fill",
        // 仕事・勉強
        "briefcase.fill",
        "graduationcap.fill",
        "books.vertical.fill",
        "laptopcomputer",
        // ライフスタイル
        "cart.fill",
        "gift.fill",
        "gamecontroller.fill",
        "music.note",
        // お金
        "creditcard.fill",
        "yensign.circle.fill",
        "banknote.fill",
        "dollarsign.circle.fill",
        // その他
        "star.fill",
        "calendar",
        "tag.fill",
        "sparkles"
    ]

    /// Premium 限定アイコン (より細かい用途・シーン別に分けたい人向け)
    static let premiumOptions: [String] = {
        var s: [String] = []
        s.append(contentsOf: lifeAndHome)
        s.append(contentsOf: workAndStudy)
        s.append(contentsOf: travelAndLeisure)
        s.append(contentsOf: hobbiesAndEntertainment)
        s.append(contentsOf: financeAndShopping)
        s.append(contentsOf: healthAndSports)
        s.append(contentsOf: familyAndPeople)
        s.append(contentsOf: foodAndDrink)
        s.append(contentsOf: seasonalAndEvents)
        s.append(contentsOf: misc)
        // 無料カタログとの重複を除外
        var seen = Set(freeOptions)
        return s.filter { seen.insert($0).inserted }
    }()

    /// 全アイコン (Free + Premium)
    static let allOptions: [String] = freeOptions + premiumOptions

    /// 互換用 (= 既存コード参照向け、Free のみを返す)
    @available(*, deprecated, renamed: "freeOptions")
    static var options: [String] { freeOptions }

    /// シンボルが Premium 限定か
    static func isPremiumSymbol(_ symbol: String) -> Bool {
        !freeOptionsSet.contains(symbol)
    }

    private static let freeOptionsSet: Set<String> = Set(freeOptions)

    // MARK: - Premium catalog (curated for sheets)

    private static let lifeAndHome: [String] = [
        "house", "house.lodge.fill", "house.and.flag.fill", "house.circle.fill",
        "building", "building.fill", "building.columns.fill",
        "bed.double", "sofa.fill", "chair.fill", "lamp.desk.fill",
        "tent.fill", "tent.2.fill",
        "key.horizontal.fill", "lock.fill", "door.left.hand.open",
        "fireplace.fill"
    ]

    private static let workAndStudy: [String] = [
        "briefcase", "case.fill", "case",
        "graduationcap", "books.vertical", "book.closed.fill", "book.pages.fill",
        "pencil.circle.fill", "ruler.fill", "highlighter",
        "doc.text.fill", "folder.fill", "tray.full.fill",
        "lightbulb.fill", "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "calendar.circle.fill", "calendar.day.timeline.left"
    ]

    private static let travelAndLeisure: [String] = [
        "airplane.circle.fill", "airplane.departure", "airplane.arrival",
        "car", "car.2.fill", "bus.fill", "tram.fill",
        "bicycle", "bicycle.circle.fill", "scooter",
        "ferry.fill", "sailboat.fill",
        "map", "globe.desk.fill", "globe.asia.australia.fill",
        "compass.drawing", "binoculars.fill",
        "suitcase.fill", "suitcase.cart.fill", "backpack.fill",
        "tent", "mountain.2.fill", "beach.umbrella.fill",
        "sun.horizon.fill", "moon.stars.fill"
    ]

    private static let hobbiesAndEntertainment: [String] = [
        "gamecontroller", "tv.fill", "film.fill", "music.note.list",
        "guitars.fill", "pianokeys.inverse", "music.mic",
        "headphones", "ticket.fill", "puzzlepiece.fill",
        "die.face.5.fill", "play.tv.fill", "play.rectangle.fill",
        "theatermasks.fill", "paintbrush.fill", "paintpalette.fill",
        "popcorn.fill", "trophy.fill", "medal.fill"
    ]

    private static let financeAndShopping: [String] = [
        "creditcard", "creditcard.and.123", "wallet.bifold.fill",
        "banknote", "yensign", "yensign.bank.building",
        "dollarsign", "eurosign", "dollarsign.bank.building",
        "chart.pie.fill", "chart.bar", "chart.xyaxis.line",
        "cart", "bag.fill", "basket.fill",
        "shippingbox.fill", "tag", "barcode.viewfinder",
        "percent"
    ]

    private static let healthAndSports: [String] = [
        "heart.circle.fill", "heart.text.square.fill",
        "cross.case.fill", "pills.fill", "stethoscope",
        "figure.run", "figure.walk", "figure.hiking",
        "figure.yoga", "figure.dance", "figure.boxing",
        "figure.skiing.downhill", "figure.surfing", "figure.cooldown",
        "tennis.racket", "soccerball", "basketball.fill", "baseball.fill",
        "dumbbell.fill", "skis.fill", "snowboard.fill"
    ]

    private static let familyAndPeople: [String] = [
        "person.fill", "person.circle.fill", "person.crop.square.fill",
        "person.2.circle.fill", "person.3.sequence.fill",
        "figure.and.child.holdinghands", "figure.2.and.child.holdinghands",
        "stroller.fill", "teddybear.fill",
        "person.badge.plus", "person.crop.rectangle.stack.fill"
    ]

    private static let foodAndDrink: [String] = [
        "fork.knife.circle.fill", "cup.and.saucer.fill", "wineglass.fill",
        "mug.fill", "birthday.cake.fill", "carrot.fill",
        "takeoutbag.and.cup.and.straw.fill", "popcorn.fill",
        "fish.fill", "frying.pan.fill"
    ]

    private static let seasonalAndEvents: [String] = [
        "snowman.fill", "balloon.fill", "party.popper.fill",
        "gift.circle.fill", "calendar.badge.plus", "fireworks",
        "rainbow", "sparkles.rectangle.stack.fill",
        "leaf.fill", "snowflake.circle.fill"
    ]

    private static let misc: [String] = [
        "star.circle.fill", "star.square.fill", "star.leadinghalf.filled",
        "bookmark.fill", "flag.fill", "flag.checkered",
        "rosette", "crown.fill",
        "globe", "globe.americas.fill", "globe.europe.africa.fill",
        "moon.fill", "sun.max.fill", "cloud.fill",
        "umbrella.fill", "shield.fill", "lock.shield",
        "hourglass", "stopwatch.fill", "alarm.fill",
        "lightbulb", "bell.fill", "bookmark",
        "infinity", "atom", "asterisk.circle.fill"
    ]
}
