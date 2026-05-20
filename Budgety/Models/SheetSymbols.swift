//
//  SheetSymbols.swift
//  Budgety
//
//  シート (= グループ・予算) のアイコン選択肢。
//  カテゴリの SF Symbol とは別に、シートの性格に合うものをキュレーション。
//  Premium ユーザーは Premium 限定の追加カタログも選択可。
//
//  注意: 各シンボル名は SF Symbols 5/6/7 で名前が変わったり、特定 OS で
//  存在しないものもある。`isSymbolAvailable(_:)` で実行時にプラットフォーム
//  に存在するかチェックし、ピッカー表示前にフィルタする (= 「？」アイコンの
//  プレースホルダが出るのを防ぐ)。
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum SheetSymbols {
    /// 指定シンボルが現在のプラットフォームに存在するか。
    /// 存在しないシンボル名を渡すと `UIImage(systemName:)` / `NSImage(systemSymbolName:)`
    /// は nil を返すので、それで判定できる。
    static func isSymbolAvailable(_ symbol: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: symbol) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        #else
        return true
        #endif
    }

    /// `rawFreeOptions` から OS に存在するシンボルだけを返す。
    static let freeOptions: [String] = rawFreeOptions.filter(isSymbolAvailable)

    /// 無料ユーザーが選べる基本アイコン (raw, OS チェック前)
    private static let rawFreeOptions: [String] = [
        // 人・グループ系
        "person.2.fill",
        "person.3.fill",
        "person.crop.circle.fill",
        "heart.fill",
        "figure.and.child.holdinghands",
        // 家・建物
        "house.fill",
        "building.2.fill",
        "bed.double.fill",
        "fork.knife",
        "sofa.fill",
        // 旅行・移動
        "airplane",
        "car.fill",
        "tram.fill",
        "map.fill",
        "suitcase.fill",
        // 仕事・勉強
        "briefcase.fill",
        "graduationcap.fill",
        "books.vertical.fill",
        "laptopcomputer",
        "pencil.tip.crop.circle",
        // ライフスタイル
        "cart.fill",
        "gift.fill",
        "gamecontroller.fill",
        "music.note",
        "tv.fill",
        // お金
        "creditcard.fill",
        "yensign.circle.fill",
        "banknote.fill",
        "dollarsign.circle.fill",
        "wallet.bifold.fill",
        // その他
        "star.fill",
        "calendar",
        "tag.fill",
        "sparkles",
        "heart.circle.fill"
    ]

    /// Premium 限定アイコン (より細かい用途・シーン別に分けたい人向け)
    /// OS に存在しないシンボルは自動的に除外される。
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
        // 無料カタログとの重複を除外 + 存在しないシンボルを除外
        var seen = Set(freeOptions)
        return s.filter { isSymbolAvailable($0) && seen.insert($0).inserted }
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


    // MARK: - Section structure (for UI grouping)

    /// セクション単位の SF Symbol カタログ。タイトル + シンボル配列を保持。
    struct Section: Identifiable {
        let id: String
        let title: String
        let symbols: [String]
    }

    /// シンボル選択 UI で section ごとに見出し付きで表示するための一覧。
    /// 各 section の symbols は OS に存在するものだけにフィルタ済み。
    /// (フィルタの結果空になったセクションは除外)
    static let sections: [Section] = [
        Section(id: "free",                  title: "基本",           symbols: freeOptions),
        Section(id: "lifeAndHome",           title: "家・暮らし",     symbols: lifeAndHome.filter(isSymbolAvailable)),
        Section(id: "workAndStudy",          title: "仕事・勉強",     symbols: workAndStudy.filter(isSymbolAvailable)),
        Section(id: "travelAndLeisure",      title: "旅行・移動",     symbols: travelAndLeisure.filter(isSymbolAvailable)),
        Section(id: "hobbiesAndEntertainment", title: "趣味・娯楽",  symbols: hobbiesAndEntertainment.filter(isSymbolAvailable)),
        Section(id: "financeAndShopping",    title: "お金・買い物",   symbols: financeAndShopping.filter(isSymbolAvailable)),
        Section(id: "healthAndSports",       title: "健康・スポーツ", symbols: healthAndSports.filter(isSymbolAvailable)),
        Section(id: "familyAndPeople",       title: "家族・人",       symbols: familyAndPeople.filter(isSymbolAvailable)),
        Section(id: "foodAndDrink",          title: "食べ物・飲み物", symbols: foodAndDrink.filter(isSymbolAvailable)),
        Section(id: "seasonalAndEvents",     title: "季節・イベント", symbols: seasonalAndEvents.filter(isSymbolAvailable)),
        Section(id: "misc",                  title: "その他",         symbols: misc.filter(isSymbolAvailable))
    ].filter { !$0.symbols.isEmpty }

    // MARK: - Premium catalog (curated for sheets)

    private static let lifeAndHome: [String] = [
        "house", "house.lodge.fill", "house.and.flag.fill", "house.circle.fill",
        "building", "building.fill", "building.columns.fill",
        "building.2.crop.circle.fill", "warehouse.fill",
        "bed.double", "sofa", "chair.fill", "chair.lounge.fill",
        "lamp.desk.fill", "lamp.table.fill", "lamp.floor.fill",
        "lamp.ceiling.fill",
        "tent.fill", "tent.2.fill",
        "key.horizontal.fill", "key.fill", "lock.fill", "lock.open.fill",
        "door.left.hand.open", "door.left.hand.closed", "door.garage.closed",
        "door.french.closed", "door.sliding.left.hand.closed",
        "door.right.hand.open", "door.right.hand.closed",
        "fireplace.fill", "shower.fill", "bathtub.fill",
        "washer.fill", "dryer.fill", "refrigerator.fill",
        "oven.fill", "stove.fill", "dishwasher.fill",
        "toilet.fill", "sink.fill",
        "cooktop.fill", "microwave.fill",
        "spigot.fill", "humidifier.fill", "air.purifier.fill",
        "fan.ceiling.fill", "fan.floor.fill", "fan.desk.fill",
        "houseplant.fill", "leaf.fill",
        "blinds.horizontal.closed", "curtains.closed",
        "stairs", "popcorn",
        "carrot", "globe.desk.fill",
        "tv.and.mediabox.fill", "videoprojector.fill",
        "trash.fill", "trash.circle.fill",
        "hammer.fill", "screwdriver.fill", "wrench.adjustable.fill",
        "pin.square.fill", "house.lodge",
        // 追加
        "tablecells.fill",
        "lightswitch.on", "lightswitch.off",
        "air.conditioner.horizontal.fill",
        "dehumidifier.fill",
        "wallpaper",
        "window.casement", "window.shade.closed", "window.vertical.closed",
        "vase.fill",
        "tropicalstorm",
        "drop.degreesign.fill",
        "fire.extinguisher.fill",
        "ladder",
        "powerplug.fill",
        "outdent",
        "lock.square.fill", "lock.rectangle.fill",
        "alarm.waves.left.and.right.fill",
        "switch.programmable"
    ]

    private static let workAndStudy: [String] = [
        "briefcase", "briefcase.circle.fill", "case.fill", "case", "suitcase.cart.fill",
        "graduationcap", "books.vertical", "book.closed.fill", "book.pages.fill",
        "book.fill", "magazine.fill", "newspaper.fill",
        "text.book.closed.fill", "books.vertical.circle.fill",
        "pencil.circle.fill", "pencil.and.ruler.fill",
        "pencil.line", "pencil.tip", "ruler.fill", "highlighter",
        "paperclip", "paperclip.circle.fill", "scissors", "tape.fill",
        "doc.text.fill", "doc.richtext.fill", "doc.append.fill",
        "doc.on.doc.fill", "doc.text.image.fill",
        "doc.zipper", "doc.badge.gearshape.fill",
        "folder.fill", "folder.badge.plus", "folder.circle.fill",
        "tray.full.fill", "tray.2.fill",
        "lightbulb.fill", "lightbulb.max.fill", "lightbulb.led.fill",
        "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "chart.pie", "chart.dots.scatter",
        "chart.line.downtrend.xyaxis", "chart.line.flattrend.xyaxis",
        "calendar.circle.fill", "calendar.day.timeline.left",
        "calendar.day.timeline.right",
        "clock.fill", "clock.badge.fill", "clock.arrow.circlepath",
        "alarm.waves.left.and.right.fill",
        "envelope.fill", "envelope.open.fill", "envelope.badge.fill",
        "paperplane.fill", "paperplane.circle.fill",
        "desktopcomputer", "keyboard.fill", "printer.fill",
        "display", "macmini.fill", "ipad", "iphone",
        "applewatch", "applescript.fill",
        "studentdesk", "graduationcap.fill",
        "list.clipboard.fill", "list.bullet.clipboard.fill",
        "checkmark.rectangle.stack.fill",
        "person.text.rectangle.fill",
        "abc", "textformat", "function",
        "square.text.square.fill",
        "tablecells.fill"
    ]

    private static let travelAndLeisure: [String] = [
        "airplane.circle.fill", "airplane.departure", "airplane.arrival",
        "car", "car.2.fill", "car.side.fill", "car.circle.fill",
        "bus.fill", "bus.doubledecker.fill", "tram.fill",
        "tram.fill.tunnel", "train.side.front.car",
        "train.side.middle.car", "cablecar.fill",
        "bicycle", "bicycle.circle.fill", "scooter",
        "motorcycle.fill",
        "ferry.fill", "sailboat.fill", "fuelpump.fill",
        "fuelpump.circle.fill", "ev.charger.fill",
        "map", "map.circle.fill", "globe.desk.fill",
        "globe.asia.australia.fill",
        "globe.central.south.asia.fill", "globe.europe.africa.fill",
        "globe.americas.fill", "globe",
        "compass.drawing", "binoculars.fill",
        "location.fill", "location.north.fill", "location.circle.fill",
        "mappin", "mappin.circle.fill", "mappin.and.ellipse",
        "suitcase.fill", "suitcase.cart.fill", "suitcase.rolling.fill",
        "backpack.fill",
        "tent", "mountain.2.fill", "beach.umbrella.fill",
        "sun.horizon.fill", "moon.stars.fill",
        "snow", "leaf.arrow.circlepath",
        "camera.fill", "camera.macro", "photo.fill",
        "photo.stack.fill",
        "passport",
        "ticket", "lanyardcard.fill",
        "fork.knife.circle", "house.lodge",
        "wifi", "wifi.router.fill",
        "signpost.right.fill", "road.lanes",
        "road.lane.arrowtriangle.2.inward",
        // 追加
        "truck.box.fill", "truck.pickup.side.fill", "van.fill",
        "tram.tunnel.fill", "lightrail.fill",
        "fish.fill", "bird.fill",
        "snowflake", "leaf.fill",
        "drop.fill",
        "tree.fill", "tree.circle.fill",
        "wineglass", "wineglass.fill",
        "fork.knife", "cup.and.saucer.fill",
        "torch", "popcorn.fill",
        "balloon.fill",
        "person.2.wave.2.fill",
        "figure.run", "figure.walk",
        "tennis.racket"
    ]

    private static let hobbiesAndEntertainment: [String] = [
        "gamecontroller", "gamecontroller.fill", "arcade.stick",
        "arcade.stick.console",
        "tv.fill", "tv.inset.filled", "appletv.fill",
        "film.fill", "film.stack.fill", "movieclapper.fill",
        "music.note.list", "music.quarternote.3",
        "music.note.house.fill",
        "guitars.fill", "pianokeys.inverse", "pianokeys",
        "music.mic", "mic.fill", "mic.circle.fill",
        "headphones", "headphones.circle.fill",
        "earbuds", "earbuds.case.fill",
        "speaker.wave.3.fill", "hifispeaker.fill",
        "hifispeaker.2.fill", "homepod.fill",
        "ticket.fill", "puzzlepiece.fill", "puzzlepiece.extension.fill",
        "die.face.5.fill", "die.face.3.fill", "die.face.1.fill",
        "play.tv.fill", "play.rectangle.fill", "play.circle.fill",
        "play.square.stack.fill",
        "theatermasks.fill", "theatermask.and.paintbrush.fill",
        "paintbrush.fill", "paintbrush.pointed.fill", "paintpalette.fill",
        "popcorn.fill", "trophy.fill", "medal.fill",
        "camera.aperture", "camera.shutter.button.fill",
        "circle.hexagongrid.fill", "guitars",
        "balloon.2.fill", "balloon.fill",
        "books.vertical.circle.fill",
        "books.vertical",
        "tennisball", "soccerball.circle.fill",
        "skateboard.fill",
        "fishingrod.fill", "checkerboard.rectangle",
        "vinyl.fill", "record.circle.fill",
        // 追加
        "metronome.fill", "metronome",
        "tuningfork",
        "music.microphone.circle.fill",
        "music.note.house",
        "music.quarternote.3",
        "speaker.zzz.fill",
        "headphones.circle",
        "die.face.2.fill", "die.face.4.fill", "die.face.6.fill",
        "checkmark.gobackward",
        "scribble", "highlighter",
        "paintpalette",
        "popcorn",
        "trophy", "medal", "rosette",
        "crown.fill", "crown",
        "movieclapper",
        "tv.circle.fill", "video.fill",
        "play.square.fill",
        "pause.circle.fill",
        "guitars.fill",
        "comb.fill"
    ]

    private static let financeAndShopping: [String] = [
        "creditcard", "creditcard.and.123", "creditcard.viewfinder",
        "creditcard.circle.fill",
        "wallet.bifold.fill", "wallet.pass.fill",
        "banknote", "banknote.fill",
        "yensign", "yensign.bank.building", "yensign.circle.fill",
        "yensign.square.fill",
        "dollarsign", "dollarsign.bank.building", "dollarsign.square.fill",
        "dollarsign.circle.fill",
        "eurosign", "eurosign.circle.fill",
        "sterlingsign", "sterlingsign.circle.fill",
        "wonsign", "wonsign.circle.fill",
        "indianrupeesign", "francsign",
        "rublesign", "lirasign",
        "chart.pie.fill", "chart.bar", "chart.xyaxis.line",
        "chart.line.uptrend.xyaxis.circle.fill",
        "chart.bar.xaxis", "chart.line.downtrend.xyaxis.circle.fill",
        "cart", "cart.fill.badge.plus", "cart.circle.fill",
        "bag.fill", "bag.circle.fill", "bag.badge.plus",
        "basket.fill", "handbag.fill", "handbag",
        "shippingbox.fill", "shippingbox.and.arrow.backward.fill",
        "shippingbox.circle.fill",
        "tag", "tag.circle.fill", "barcode.viewfinder", "barcode",
        "qrcode", "percent",
        "giftcard.fill", "giftcard",
        "building.columns.circle.fill",
        "scalemass.fill",
        "scroll.fill",
        "doc.text.below.ecg",
        "list.bullet.rectangle.portrait.fill",
        "rectangle.stack.fill",
        "arrow.left.arrow.right.circle.fill",
        "arrow.up.arrow.down.circle.fill",
        "arrow.triangle.swap",
        // 追加
        "creditcard.trianglebadge.exclamationmark",
        "purchased.circle.fill",
        "cart.fill",
        "bag", "bag.fill",
        "shippingbox", "archivebox.fill",
        "tray.full.fill",
        "scope",
        "chart.dots.scatter",
        "chart.line.flattrend.xyaxis",
        "chart.bar.fill",
        "chart.bar.doc.horizontal.fill",
        "calendar.badge.clock",
        "stopwatch.fill",
        "creditcard.fill",
        "key.viewfinder"
    ]

    private static let healthAndSports: [String] = [
        "heart.circle.fill", "heart.text.square.fill", "heart.text.clipboard.fill",
        "heart.square.fill", "heart.slash.fill",
        "cross.case.fill", "cross.vial.fill", "pills.fill", "pill.fill",
        "stethoscope", "stethoscope.circle.fill",
        "syringe.fill", "bandage.fill",
        "thermometer.medium", "thermometer.sun.fill", "thermometer.snowflake",
        "facemask.fill", "lungs.fill", "brain.fill", "brain.head.profile.fill",
        "eye.fill", "eyes",
        "figure.run", "figure.walk", "figure.hiking", "figure.outdoor.cycle",
        "figure.yoga", "figure.dance", "figure.boxing", "figure.fencing",
        "figure.skiing.downhill", "figure.snowboarding",
        "figure.surfing", "figure.cooldown", "figure.strengthtraining.traditional",
        "figure.pool.swim", "figure.basketball", "figure.american.football",
        "figure.golf", "figure.tennis", "figure.badminton",
        "figure.archery", "figure.bowling", "figure.climbing",
        "figure.gymnastics", "figure.handball", "figure.skating",
        "figure.skateboarding", "figure.martial.arts",
        "figure.indoor.cycle",
        "tennis.racket", "soccerball", "basketball.fill", "baseball.fill",
        "football.fill", "rugby.ball.fill", "volleyball.fill",
        "tennisball.fill", "hockey.puck.fill", "cricket.ball.fill",
        "dumbbell.fill", "skis.fill", "snowboard.fill",
        "bowling.ball.fill", "tennis.racket.circle.fill",
        "trophy.circle.fill"
    ]

    private static let familyAndPeople: [String] = [
        "person.fill", "person.circle.fill", "person.crop.square.fill",
        "person.crop.rectangle.fill", "person.crop.circle",
        "person.2.circle.fill", "person.3.sequence.fill",
        "person.2.crop.square.stack.fill",
        "figure.2.and.child.holdinghands",
        "figure.and.child.holdinghands",
        "stroller.fill", "teddybear.fill", "carseat.right.fill",
        "person.badge.plus", "person.badge.shield.checkmark.fill",
        "person.badge.key.fill", "person.badge.clock.fill",
        "person.crop.rectangle.stack.fill",
        "person.crop.artframe",
        "person.line.dotted.person.fill",
        "figure.child", "figure.child.circle.fill",
        "figure.wave",
        "graduationcap.circle.fill",
        "pawprint.fill", "pawprint.circle.fill",
        "dog.fill", "dog.circle.fill",
        "cat.fill", "cat.circle.fill",
        "bird.fill", "bird.circle.fill",
        "fish", "tortoise.fill", "hare.fill",
        "lizard.fill", "ladybug.fill", "ant.fill",
        // 追加
        "horse.fill", "horse",
        "butterfly.fill", "spider.fill",
        "feather.fill", "feather",
        "snail",
        "person.3", "person.2",
        "figure.2", "figure.stand",
        "figure.arms.open",
        "figure.wave.circle.fill"
    ]

    private static let foodAndDrink: [String] = [
        "fork.knife.circle.fill", "fork.knife.circle",
        "cup.and.saucer.fill", "cup.and.heat.waves.fill",
        "wineglass.fill", "wineglass",
        "mug.fill", "birthday.cake.fill",
        "carrot.fill",
        "takeoutbag.and.cup.and.straw.fill",
        "popcorn.fill",
        "fish.fill", "frying.pan.fill",
        "waterbottle.fill", "wineglass.frame.fill",
        "cooktop.fill",
        "fork.knife",
        "birthday.cake",
        "cup.and.saucer", "mug",
        "popcorn", "carrot",
        "fish", "frying.pan",
        "takeoutbag.and.cup.and.straw",
        "leaf",
        "drop.fill", "drop",
        "flame.fill", "flame",
        "sandwich.fill", "tea.fill",
        "fish.circle.fill",
        // 追加
        "wineglass.circle.fill",
        "fork.knife.circle",
        "stove.fill", "oven.fill",
        "microwave.fill",
        "ladybug",
        "torch",
        "drop.degreesign.fill",
        "drop.halffull",
        "wineglass.frame",
        "flame.circle.fill"
    ]

    private static let seasonalAndEvents: [String] = [
        "snowman.fill", "snowflake",
        "balloon.fill", "balloon.2.fill",
        "party.popper.fill", "fireworks",
        "gift.circle.fill", "gift.fill",
        "calendar.badge.plus", "calendar.badge.exclamationmark",
        "calendar.badge.clock", "calendar.badge.checkmark",
        "rainbow",
        "sparkles.rectangle.stack.fill",
        "sparkles",
        "leaf.fill", "leaf.circle.fill",
        "snowflake.circle.fill",
        "sun.max.fill", "sun.rain.fill",
        "sun.dust.fill", "sun.haze.fill",
        "moon.fill", "moon.circle.fill",
        "moon.zzz.fill",
        "cloud.heavyrain.fill", "cloud.snow.fill", "cloud.bolt.fill",
        "cloud.fog.fill", "cloud.drizzle.fill", "cloud.hail.fill",
        "cloud.sun.fill", "cloud.moon.fill",
        "wind", "tornado", "hurricane",
        "tree.fill", "tree.circle.fill",
        "camera.macro.circle.fill",
        "thermometer.sun.circle.fill",
        "moon.haze.fill",
        "star.fill", "star.circle.fill",
        "sun.and.horizon.fill",
        "smoke.fill",
        // 追加
        "tropicalstorm",
        "wind.snow",
        "sun.rain.circle.fill",
        "cloud.bolt.rain.fill",
        "moon.stars",
        "sparkles",
        "wand.and.stars.inverse",
        "balloon", "balloon.2",
        "party.popper",
        "fireworks", "lightspectrum.horizontal",
        "snowflake.circle",
        "leaf.arrow.circlepath",
        "humidity",
        "rays", "sun.snow.fill"
    ]

    private static let misc: [String] = [
        "star.circle.fill", "star.square.fill", "star.leadinghalf.filled",
        "bookmark.fill", "bookmark.circle.fill",
        "flag.fill", "flag.checkered", "flag.2.crossed.fill",
        "flag.circle.fill", "flag.slash.fill",
        "rosette", "crown.fill", "medal.star.fill",
        "globe", "globe.americas.fill", "globe.europe.africa.fill",
        "globe.asia.australia.fill",
        "moon.fill", "sun.max.fill", "cloud.fill",
        "umbrella.fill", "shield.fill", "lock.shield",
        "hourglass", "stopwatch.fill", "alarm.fill", "timer",
        "lightbulb", "bell.fill", "bell.badge.fill", "bookmark",
        "infinity", "atom", "asterisk.circle.fill",
        "checkmark.seal.fill", "exclamationmark.shield.fill",
        "questionmark.circle.fill", "info.circle.fill",
        "tag.square.fill", "pin.fill", "pin.circle.fill",
        "wand.and.stars", "wand.and.rays",
        "magnifyingglass.circle.fill",
        "flame.fill", "drop.fill", "bolt.fill",
        "scribble.variable",
        "circle.grid.2x2.fill", "square.grid.3x3.fill",
        "square.grid.4x3.fill", "rectangle.3.group.fill",
        "rectangle.grid.2x2.fill",
        "heart.slash.fill", "heart.text.square.fill",
        "diamond.fill", "hexagon.fill", "octagon.fill",
        "triangle.fill", "square.fill", "rhombus.fill",
        "circle.fill", "capsule.fill",
        "seal.fill", "sealedenvelope.fill",
        "rays", "burst.fill",
        "sparkle",
        "key.viewfinder",
        "qrcode.viewfinder",
        "viewfinder.circle.fill",
        "person.fill.questionmark",
        "exclamationmark.bubble.fill",
        "checkmark.circle.fill",
        "xmark.circle.fill",
        "plus.circle.fill",
        "minus.circle.fill",
        // 追加
        "scope", "target",
        "shield.lefthalf.filled",
        "shield.checkered",
        "rosette",
        "umbrella",
        "hand.thumbsup.fill", "hand.thumbsdown.fill",
        "hand.raised.fill", "hand.wave.fill",
        "ear.fill", "eye.fill", "mouth.fill",
        "brain.head.profile.fill",
        "bell.slash.fill",
        "lightbulb.fill", "lightbulb.led.fill",
        "lightbulb.max.fill",
        "moon.zzz",
        "battery.100.bolt", "battery.0",
        "powerplug.fill",
        "speedometer",
        "gauge.with.dots.needle.67percent",
        "puzzlepiece.fill",
        "puzzlepiece",
        "wand.and.stars.inverse"
    ]
}
