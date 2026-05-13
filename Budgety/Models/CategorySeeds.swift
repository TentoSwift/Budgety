//
//  CategorySeeds.swift
//  Budgety
//

import Foundation

struct CategorySeed {
    let name: String
    let colorHex: String
    let symbol: String
    var kind: TransactionKind = .expense
}

enum CategoryDefaults {
    /// 支出カテゴリ (新規シート作成時の初期セット)
    static let expenseSeeds: [CategorySeed] = [
        .init(name: "食費", colorHex: "#FF9500", symbol: "fork.knife"),
        .init(name: "交通", colorHex: "#5B8DEF", symbol: "car.fill"),
        .init(name: "住居", colorHex: "#A2845E", symbol: "house.fill"),
        .init(name: "光熱費", colorHex: "#FFCC00", symbol: "bolt.fill"),
        .init(name: "娯楽", colorHex: "#FF2D55", symbol: "gamecontroller.fill"),
        .init(name: "買い物", colorHex: "#AF52DE", symbol: "cart.fill"),
        .init(name: "医療", colorHex: "#FF3B30", symbol: "cross.case.fill"),
        .init(name: "教育", colorHex: "#5856D6", symbol: "book.fill"),
        .init(name: "旅行", colorHex: "#5AC8FA", symbol: "airplane"),
        .init(name: "その他", colorHex: "#8E8E93", symbol: "ellipsis.circle.fill")
    ]

    /// 収入カテゴリ
    static let incomeSeeds: [CategorySeed] = [
        .init(name: "給料", colorHex: "#34C759", symbol: "briefcase.fill", kind: .income),
        .init(name: "ボーナス", colorHex: "#30B0C7", symbol: "gift.fill", kind: .income),
        .init(name: "副業", colorHex: "#FF9500", symbol: "hammer.fill", kind: .income),
        .init(name: "投資", colorHex: "#5856D6", symbol: "chart.line.uptrend.xyaxis", kind: .income),
        .init(name: "その他収入", colorHex: "#8E8E93", symbol: "plus.circle.fill", kind: .income)
    ]

    /// 互換用 (旧コード参照)
    static let seeds: [CategorySeed] = expenseSeeds + incomeSeeds

    static let other = expenseSeeds.last!

    // MARK: - Symbol Catalog

    /// 無料ユーザーが選べる SF Symbol カタログ。シート初期 seed と日常用途を網羅。
    static let freeSymbols: [String] = [
        "fork.knife", "cup.and.saucer.fill", "wineglass.fill", "birthday.cake.fill", "carrot.fill",
        "car.fill", "bus.fill", "tram.fill", "airplane", "bicycle", "fuelpump.fill",
        "house.fill", "bed.double.fill", "lightbulb.fill", "drop.fill", "flame.fill", "bolt.fill",
        "cart.fill", "bag.fill", "tag.fill", "gift.fill", "creditcard.fill",
        "gamecontroller.fill", "tv.fill", "music.note", "film.fill", "headphones",
        "cross.case.fill", "pills.fill", "bandage.fill", "heart.fill",
        "book.fill", "graduationcap.fill", "pencil", "studentdesk",
        "dumbbell.fill", "figure.run", "tennis.racket", "soccerball",
        "pawprint.fill", "leaf.fill", "tshirt.fill", "scissors",
        "wrench.and.screwdriver.fill", "hammer.fill", "trash.fill",
        "yensign.circle.fill", "dollarsign.circle.fill", "creditcard.and.123",
        "phone.fill", "envelope.fill", "wifi", "globe",
        "person.fill", "person.2.fill", "figure.and.child.holdinghands",
        "ellipsis.circle.fill", "questionmark.circle.fill", "star.fill", "sparkles"
    ]

    /// Premium ユーザーだけが選べる追加 SF Symbol。約 1000 種類のキュレーション。
    /// 無料カタログとの重複は無し。
    static let premiumSymbols: [String] = {
        var s: [String] = []
        s.append(contentsOf: SFCatalog.foodAndDrink)
        s.append(contentsOf: SFCatalog.transport)
        s.append(contentsOf: SFCatalog.homeAndAppliance)
        s.append(contentsOf: SFCatalog.shoppingAndMoney)
        s.append(contentsOf: SFCatalog.entertainmentAndMedia)
        s.append(contentsOf: SFCatalog.sportsAndFitness)
        s.append(contentsOf: SFCatalog.healthAndMedical)
        s.append(contentsOf: SFCatalog.educationAndWork)
        s.append(contentsOf: SFCatalog.devicesAndTech)
        s.append(contentsOf: SFCatalog.communication)
        s.append(contentsOf: SFCatalog.petsAndNature)
        s.append(contentsOf: SFCatalog.fashionAndBeauty)
        s.append(contentsOf: SFCatalog.toolsAndDIY)
        s.append(contentsOf: SFCatalog.travelAndOutdoor)
        s.append(contentsOf: SFCatalog.familyAndKids)
        s.append(contentsOf: SFCatalog.seasonsAndHolidays)
        s.append(contentsOf: SFCatalog.weatherAndNature)
        s.append(contentsOf: SFCatalog.figures)
        s.append(contentsOf: SFCatalog.symbolsAndMisc)
        // 無料カタログとの重複を除外
        var seen = Set(freeSymbols)
        return s.filter { seen.insert($0).inserted }
    }()

    /// 全アイコン (= 無料 + Premium)。グリッド表示順は free 優先 + premium 後追加。
    static let allSymbols: [String] = freeSymbols + premiumSymbols

    /// アイコン文字列が Premium 限定かどうか。
    static func isPremiumSymbol(_ symbol: String) -> Bool {
        // freeSymbols 集合を使って高速判定
        !freeSymbolSet.contains(symbol)
    }

    private static let freeSymbolSet: Set<String> = Set(freeSymbols)

    /// 旧名互換 (= まだ参照しているコード向け)。
    @available(*, deprecated, renamed: "freeSymbols")
    static var availableSymbols: [String] { freeSymbols }

    /// カテゴリのカラーパレット (Hex)
    static let palette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#5B8DEF",
        "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93", "#000000"
    ]
}

enum MemberDefaults {
    /// メンバーアバターの背景色パレット (写真未設定時のフォールバック用)
    static let palette: [String] = CategoryDefaults.palette
}

// MARK: - SF Symbol Catalog (Premium)

/// カテゴリ別に SF Symbol をキュレーション。CategoryDefaults.premiumSymbols から参照される。
private enum SFCatalog {
    static let foodAndDrink: [String] = [
        "takeoutbag.and.cup.and.straw.fill", "popcorn.fill", "fish.fill", "frying.pan.fill",
        "mug.fill", "cup.and.heat.waves.fill", "wineglass", "waterbottle.fill",
        "cooktop.fill", "stove.fill", "oven.fill", "microwave.fill", "dishwasher.fill",
        "carrot", "popcorn", "birthday.cake", "wineglass.fill", "fork.knife.circle",
        "fork.knife.circle.fill", "cup.and.saucer", "mug", "takeoutbag.and.cup.and.straw"
    ]

    static let transport: [String] = [
        "tram.tunnel.fill", "ferry.fill", "sailboat.fill", "scooter",
        "fuelpump.arrowtriangle.left.fill", "parkingsign.circle.fill", "engine.combustion.fill",
        "car", "car.2.fill", "car.side.fill", "car.front.waves.up.fill", "car.rear.fill",
        "bus", "bus.doubledecker.fill", "tram", "cablecar.fill", "lightrail.fill",
        "bicycle.circle", "bicycle.circle.fill", "motorcycle.fill", "truck.box.fill",
        "truck.pickup.side.fill", "fuelpump", "ev.charger.fill", "ev.charger",
        "parkingsign", "minus.fuelpump.fill", "road.lanes", "road.lane.arrowtriangle.2.inward",
        "steeringwheel", "carseat.left.fill", "carseat.right.fill",
        "airplane.circle.fill", "airplane.departure", "airplane.arrival",
        "ferry", "sailboat", "fish.circle.fill", "fishhook"
    ]

    static let homeAndAppliance: [String] = [
        "building.2.fill", "building.columns.fill", "lightswitch.on", "key.horizontal.fill",
        "shower.fill", "washer.fill", "refrigerator.fill", "spigot.fill",
        "building.fill", "building", "house", "house.lodge.fill", "house.and.flag.fill",
        "house.circle.fill", "tent.fill", "tent.2.fill",
        "bed.double", "sofa.fill", "chair.fill", "lamp.desk.fill", "lamp.floor.fill",
        "lamp.table.fill", "lamp.ceiling.fill", "fan.fill", "fan.floor.fill",
        "fireplace.fill", "stairs", "door.left.hand.open", "door.right.hand.open",
        "door.garage.closed", "door.garage.open", "door.french.closed", "door.french.open",
        "window.casement", "window.shade.closed", "blinds.horizontal.closed", "blinds.vertical.closed",
        "lock.fill", "lock.shield.fill", "key.fill", "alarm.fill",
        "thermometer.medium", "thermometer.sun.fill", "thermometer.snowflake",
        "humidifier.fill", "dehumidifier.fill", "air.purifier.fill", "air.conditioner.horizontal.fill",
        "drop.degreesign.fill", "drop.halffull", "spigot", "shower",
        "toilet.fill", "bathtub.fill", "sink.fill", "wineglass.fill",
        "fork.knife.circle", "dishwasher", "refrigerator", "stove", "microwave",
        "oven", "cooktop", "washer", "dryer.fill"
    ]

    static let shoppingAndMoney: [String] = [
        "basket.fill", "creditcard.viewfinder", "banknote.fill", "wallet.bifold.fill",
        "chart.line.uptrend.xyaxis", "chart.pie.fill", "percent",
        "cart", "cart.badge.plus", "cart.badge.minus", "bag", "bag.badge.plus",
        "shippingbox.fill", "shippingbox", "archivebox.fill", "tray.full.fill",
        "tag", "tag.circle.fill", "barcode", "barcode.viewfinder",
        "creditcard", "creditcard.trianglebadge.exclamationmark", "creditcard.and.123",
        "wallet.bifold", "banknote", "yensign.bank.building", "dollarsign.bank.building",
        "chart.bar.fill", "chart.bar", "chart.xyaxis.line", "chart.dots.scatter",
        "chart.line.downtrend.xyaxis", "chart.line.flattrend.xyaxis",
        "chart.pie", "chart.bar.xaxis", "scalemass.fill",
        "yensign", "dollarsign", "eurosign", "sterlingsign", "wonsign",
        "yensign.square.fill", "dollarsign.square.fill", "eurosign.square.fill",
        "yensign.circle", "dollarsign.circle", "eurosign.circle",
        "purchased.circle.fill", "rosette", "trophy.fill", "medal.fill", "crown.fill"
    ]

    static let entertainmentAndMedia: [String] = [
        "guitars.fill", "music.mic", "theatermasks.fill", "ticket.fill", "popcorn",
        "puzzlepiece.fill", "die.face.5.fill", "play.tv.fill",
        "tv", "tv.circle.fill", "play.rectangle.fill", "play.square.fill",
        "film", "film.circle.fill", "video.fill", "video.circle.fill",
        "play.circle.fill", "pause.circle.fill", "stop.circle.fill",
        "music.note.list", "music.quarternote.3", "music.mic.circle.fill",
        "guitars", "pianokeys", "pianokeys.inverse", "metronome.fill",
        "speaker.wave.3.fill", "speaker.wave.2.fill", "speaker.fill", "speaker.slash.fill",
        "headphones.circle.fill", "earbuds.case.fill", "earbuds.case",
        "die.face.1.fill", "die.face.2.fill", "die.face.3.fill", "die.face.4.fill",
        "die.face.6.fill", "puzzlepiece", "tortoise.fill", "hare.fill",
        "ticket", "popcorn.circle.fill",
        "theatermasks", "paintbrush.pointed.fill", "paintpalette.fill",
        "tennis.racket.circle.fill", "soccerball.circle.fill",
        "basketball.fill", "football.fill", "baseball.fill", "volleyball.fill",
        "trophy", "medal", "rosette",
        "play.rectangle", "rectangle.stack.fill", "rectangle.stack.badge.play.fill"
    ]

    static let sportsAndFitness: [String] = [
        "stethoscope", "heart.text.clipboard.fill", "figure.yoga", "figure.surfing",
        "figure.basketball", "figure.american.football", "figure.skiing.downhill",
        "bicycle.circle.fill",
        "figure.walk", "figure.walk.circle.fill", "figure.walk.motion",
        "figure.run.circle.fill", "figure.run.square.stack.fill",
        "figure.hiking", "figure.climbing", "figure.cooldown", "figure.core.training",
        "figure.cricket", "figure.skating", "figure.skiing.crosscountry",
        "figure.snowboarding", "figure.flexibility", "figure.dance",
        "figure.archery", "figure.badminton", "figure.barre", "figure.baseball",
        "figure.bowling", "figure.boxing", "figure.curling", "figure.disc.sports",
        "figure.equestrian.sports", "figure.fencing", "figure.fishing",
        "figure.golf", "figure.handball", "figure.hockey", "figure.lacrosse",
        "figure.martial.arts", "figure.mind.and.body", "figure.outdoor.cycle",
        "figure.indoor.cycle", "figure.pickleball", "figure.pilates",
        "figure.pool.swim", "figure.racquetball", "figure.rolling",
        "figure.rower", "figure.rugby", "figure.sailing", "figure.skiing.freestyle",
        "figure.skiing.downhill.circle", "figure.snowboarding.circle",
        "figure.snowshoeing", "figure.softball", "figure.squash", "figure.stair.stepper",
        "figure.strengthtraining.functional", "figure.strengthtraining.traditional",
        "figure.surfing.circle", "figure.table.tennis", "figure.taichi",
        "figure.track.and.field", "figure.volleyball", "figure.water.fitness",
        "figure.waterpolo", "figure.wrestling",
        "tennisball.fill", "tennisball", "baseball", "basketball", "soccerball.inverse",
        "football", "volleyball", "skis.fill", "snowboard.fill", "skateboard.fill",
        "surfboard.fill", "oar.2.crossed", "dumbbell"
    ]

    static let healthAndMedical: [String] = [
        "stethoscope.circle.fill", "cross.case", "cross.case.circle.fill",
        "pills", "pill.fill", "syringe.fill", "facemask.fill", "ivfluid.bag.fill",
        "medical.thermometer.fill", "medical.thermometer",
        "heart.circle.fill", "heart.text.square.fill", "heart.slash.fill",
        "ear.fill", "eye.fill", "nose.fill", "mouth.fill", "tooth.fill",
        "lungs.fill", "brain.head.profile", "brain.fill", "brain",
        "bandage", "cross.fill", "cross.circle.fill", "cross",
        "waveform.path.ecg.rectangle.fill", "waveform.path.ecg",
        "heart.text.clipboard", "list.clipboard.fill", "clipboard.fill",
        "drop.degreesign.slash.fill", "humidity.fill", "thermometer.high",
        "thermometer.low", "stethoscope", "allergens.fill", "allergens"
    ]

    static let educationAndWork: [String] = [
        "books.vertical.fill", "newspaper.fill", "doc.fill", "paperclip",
        "briefcase.fill", "case.fill", "laptopcomputer", "keyboard.fill",
        "books.vertical", "book.closed.fill", "book.closed", "book.pages.fill",
        "graduationcap", "graduationcap.circle.fill",
        "pencil.circle.fill", "pencil.tip.crop.circle.fill", "pencil.and.outline",
        "highlighter", "paintbrush.fill", "pencil.tip",
        "ruler.fill", "ruler", "scribble", "scribble.variable",
        "doc.text.fill", "doc.text", "doc.richtext.fill", "doc.plaintext.fill",
        "doc.append.fill", "doc.badge.plus", "doc.on.doc.fill",
        "folder.fill", "folder", "folder.circle.fill", "folder.badge.plus",
        "tray.fill", "tray.2.fill", "archivebox", "externaldrive.fill",
        "internaldrive.fill", "opticaldisc.fill",
        "magnifyingglass", "magnifyingglass.circle.fill",
        "lightbulb", "lightbulb.circle.fill", "questionmark.bubble.fill",
        "graduationcap.circle", "studentdesk",
        "calendar.circle.fill", "calendar.badge.clock", "calendar.day.timeline.left",
        "clock.fill", "clock.badge.checkmark.fill", "stopwatch.fill", "timer",
        "alarm", "deskclock.fill",
        "briefcase", "case", "suitcase.cart.fill", "suitcase.cart",
        "person.crop.rectangle.stack.fill", "person.text.rectangle.fill",
        "rectangle.and.text.magnifyingglass", "doc.text.magnifyingglass"
    ]

    static let devicesAndTech: [String] = [
        "iphone", "iphone.gen3", "ipad", "ipad.landscape", "macbook", "macpro.gen3.fill",
        "applewatch", "applewatch.case.inset.filled", "airpods", "airpodspro", "airpodsmax",
        "homepod.fill", "homepod.mini.fill", "appletv.fill", "macmini.fill",
        "display", "display.2", "tv.and.hifispeaker.fill",
        "printer.fill", "scanner.fill", "fax.fill",
        "camera.fill", "camera.circle.fill", "camera.macro", "video.fill",
        "video.bubble.left.fill", "movieclapper.fill",
        "mouse.fill", "computermouse.fill", "keyboard", "magicmouse.fill",
        "wifi.circle.fill", "wifi.router.fill", "antenna.radiowaves.left.and.right",
        "dot.radiowaves.left.and.right", "dot.radiowaves.up.forward",
        "battery.100", "battery.75", "battery.50", "battery.25", "battery.0",
        "battery.100.bolt", "powerplug.fill", "bolt.car.fill",
        "memorychip.fill", "cpu.fill", "gpu.fill", "headphones.circle",
        "bonjour", "personalhotspot",
        "sdcard.fill", "simcard.fill", "esim.fill",
        "smartphone", "phone.circle.fill", "phone.bubble.fill",
        "envelope.circle.fill", "envelope.badge.fill", "envelope.open.fill",
        "tray.and.arrow.up.fill", "tray.and.arrow.down.fill",
        "globe.americas.fill", "globe.europe.africa.fill", "globe.central.south.asia.fill",
        "globe.asia.australia.fill"
    ]

    static let communication: [String] = [
        "message.fill", "video.fill", "bubble.left.and.bubble.right.fill",
        "message", "message.circle.fill", "bubble.left.fill", "bubble.right.fill",
        "bubble.left", "bubble.right", "ellipsis.bubble.fill", "quote.bubble.fill",
        "captions.bubble.fill", "text.bubble.fill",
        "phone.fill.connection", "phone.arrow.up.right.fill", "phone.arrow.down.left.fill",
        "phone.badge.plus", "phone.circle", "phone.bubble",
        "envelope.open.badge.clock", "envelope.arrow.triangle.branch.fill",
        "tray.and.arrow.up", "tray.and.arrow.down", "paperplane.fill", "paperplane.circle.fill",
        "at.circle.fill", "at.badge.plus", "at",
        "person.crop.circle.fill.badge.plus", "person.crop.circle.fill.badge.checkmark",
        "person.line.dotted.person.fill", "person.fill.viewfinder",
        "megaphone.fill", "megaphone", "speaker.zzz.fill", "ear.badge.checkmark"
    ]

    static let petsAndNature: [String] = [
        "dog.fill", "cat.fill", "bird.fill", "ant.fill", "ladybug.fill",
        "tree.fill", "tortoise.fill", "snowflake",
        "dog", "cat", "bird", "fish", "lizard.fill", "lizard",
        "pawprint", "pawprint.circle.fill", "leaf", "leaf.circle.fill",
        "tree", "tree.circle.fill", "carrot", "fish.fill",
        "ant", "ladybug", "tortoise", "hare", "hare.fill",
        "butterfly.fill", "butterfly", "snail", "spider.fill",
        "feather", "feather.fill", "horse", "horse.fill",
        "snowman.fill", "drop", "leaf.arrow.circlepath",
        "globe.americas", "globe.europe.africa", "moon.fill", "moon.stars",
        "sun.max.fill", "sun.min.fill", "sun.haze.fill", "sun.dust.fill",
        "cloud.fill", "cloud.rain.fill", "cloud.bolt.fill", "cloud.snow.fill",
        "cloud.fog.fill", "cloud.drizzle.fill", "cloud.hail.fill",
        "cloud.sun.fill", "cloud.moon.fill", "cloud.sun.rain.fill", "cloud.sun.bolt.fill",
        "tornado", "tropicalstorm", "hurricane",
        "thermometer.sun", "thermometer.snowflake", "humidity",
        "wind", "wind.circle.fill", "wind.snow",
        "rainbow", "mountain.2.fill", "mountain.2"
    ]

    static let fashionAndBeauty: [String] = [
        "shoe.fill", "sunglasses.fill", "comb.fill", "lipstick", "eyeglasses",
        "shoe", "shoe.2.fill", "tshirt", "shoeprints.fill",
        "comb", "facemask", "necklace", "necklace.fill",
        "watch.analog", "applewatch.watchface",
        "scissors.circle.fill",
        "hanger", "tshirt.circle.fill", "jacket", "jacket.fill",
        "hat.widebrim.fill", "hat.widebrim", "hat.cap.fill", "hat.cap"
    ]

    static let toolsAndDIY: [String] = [
        "screwdriver.fill", "paintbrush.fill", "wrench.fill", "level.fill",
        "hammer", "wrench", "screwdriver", "paintbrush",
        "wrench.adjustable.fill", "wrench.adjustable",
        "hammer.circle.fill", "wrench.and.screwdriver",
        "ruler", "pencil.tip.crop.circle", "scissors",
        "paintpalette", "paintpalette.fill",
        "lightbulb.led.fill", "lightbulb.2.fill", "lightbulb.slash.fill",
        "powerplug", "bolt.batteryblock.fill"
    ]

    static let travelAndOutdoor: [String] = [
        "suitcase.fill", "tent.fill", "map.fill", "binoculars.fill",
        "suitcase", "suitcase.cart", "backpack.fill", "backpack",
        "map", "globe.desk.fill", "globe.desk", "location.fill",
        "location.circle.fill", "location.north.fill", "location.north.line.fill",
        "compass.drawing", "binoculars",
        "tent", "tent.circle.fill", "tent.2",
        "mountain.2.circle.fill", "leaf.fill", "tree.fill",
        "beach.umbrella.fill", "beach.umbrella",
        "sun.horizon.fill", "moon.haze.fill", "stars.fill",
        "ferry", "sailboat",
        "airplane.circle", "airplane.departure", "airplane.arrival",
        "ticket", "passport"
    ]

    static let familyAndKids: [String] = [
        "stroller.fill", "teddybear.fill", "carseat.left.fill",
        "stroller", "teddybear", "balloon.fill", "balloon",
        "figure.and.child.holdinghands", "figure.2.and.child.holdinghands",
        "figure.child", "figure.child.circle.fill",
        "person.2.crop.square.stack.fill", "person.3.sequence.fill",
        "gift", "gift.circle.fill", "birthday.cake", "party.popper",
        "graduationcap", "baseball.diamond.bases"
    ]

    static let seasonsAndHolidays: [String] = [
        "snowman.fill", "balloon.fill", "party.popper.fill", "calendar.badge.plus",
        "snowman", "balloon", "party.popper", "birthday.cake.fill",
        "gift.fill", "gift.circle.fill", "fireworks",
        "moon.stars.fill", "moon.zzz.fill", "star.circle.fill", "star.bubble.fill",
        "leaf.fill", "leaf.circle", "tree", "snowflake.circle.fill",
        "calendar.badge.exclamationmark", "calendar.badge.minus",
        "calendar.circle", "clock.badge",
        "flame", "flame.circle.fill", "sparkles.rectangle.stack.fill"
    ]

    static let weatherAndNature: [String] = [
        "sun.max", "sun.min", "sun.rain.fill", "sun.snow.fill", "sun.dust",
        "sun.haze", "sun.horizon", "moon", "moon.circle.fill",
        "cloud", "cloud.rain", "cloud.snow", "cloud.bolt", "cloud.drizzle",
        "cloud.fog", "cloud.hail", "cloud.heavyrain.fill", "cloud.moon",
        "cloud.sun",
        "wind.snow", "snowflake.circle", "umbrella", "umbrella.fill",
        "thermometer.medium.slash", "thermometer.brakesignal",
        "drop.circle.fill", "drop.triangle.fill", "humidity",
        "hurricane.circle.fill",
        "leaf.arrow.triangle.circlepath", "mountain.2"
    ]

    static let figures: [String] = [
        "person.crop.circle", "person.crop.square.fill", "person.crop.rectangle.fill",
        "person.circle.fill", "person.badge.plus", "person.badge.minus",
        "person.badge.key.fill", "person.badge.shield.checkmark.fill",
        "person.fill.checkmark", "person.fill.xmark", "person.fill.questionmark",
        "person.2.circle.fill", "person.3.fill", "person.3.sequence.fill",
        "person.line.dotted.person.fill", "figure.stand", "figure.wave",
        "figure.arms.open", "figure.fall", "figure.fall.circle.fill",
        "figure.seated.seatbelt", "figure.seated.side.right.air.distribution.upper.angled",
        "figure.roll", "figure.roll.runningpace"
    ]

    static let symbolsAndMisc: [String] = [
        "globe.asia.australia.fill", "moon.stars.fill", "umbrella.fill",
        "shield.lefthalf.filled", "shield.fill", "shield.checkered",
        "checkmark.shield.fill", "exclamationmark.shield.fill",
        "lock.rectangle.fill", "lock.shield", "lock.open.fill",
        "key", "key.viewfinder", "key.radiowaves.forward.fill",
        "star.leadinghalf.filled", "star.square.fill", "star.bubble",
        "flag.fill", "flag", "flag.checkered", "flag.2.crossed.fill",
        "bookmark.fill", "bookmark", "tag.slash.fill", "ticket.fill",
        "rosette", "trophy", "medal", "crown",
        "magnifyingglass.circle", "binoculars",
        "hourglass", "hourglass.circle.fill", "stopwatch", "alarm",
        "infinity", "infinity.circle.fill",
        "scope", "viewfinder", "scope",
        "arrow.up.heart.fill", "arrow.up.right.circle.fill",
        "checkmark.seal.fill", "checkmark.diamond.fill", "checkmark.rectangle.fill",
        "exclamationmark.triangle.fill", "exclamationmark.octagon.fill",
        "info.circle.fill", "info.bubble.fill", "questionmark.diamond.fill",
        "lightbulb.max.fill", "puzzlepiece.extension.fill",
        "smiley.fill", "smiley", "face.smiling.fill", "face.smiling",
        "heart.square.fill", "heart.rectangle.fill", "heart.circle",
        "diamond.fill", "diamond", "shuffle", "shuffle.circle.fill",
        "rectangle.split.3x3.fill", "square.grid.2x2.fill", "square.grid.3x3.fill",
        "circle.grid.2x2.fill", "circle.grid.3x3.fill",
        "list.bullet", "list.dash", "list.number", "list.star",
        "asterisk", "asterisk.circle.fill", "number", "number.circle.fill",
        "bell.fill", "bell.circle.fill", "bell.badge.fill", "bell.slash.fill",
        "tag.fill", "tag.circle", "barcode.viewfinder",
        "qrcode", "qrcode.viewfinder",
        "atom", "atom",
        "rectangle.stack", "square.stack.3d.up.fill", "square.stack.3d.down.right.fill",
        "calendar.day.timeline.left", "calendar.day.timeline.right",
        "alarm.waves.left.and.right.fill", "stopwatch.fill",
        "die.face.1", "die.face.6", "puzzlepiece",
        "globe", "globe.badge.chevron.backward",
        "network", "antenna.radiowaves.left.and.right.circle.fill",
        "bonjour", "lightspectrum.horizontal",
        "wave.3.right.circle.fill", "wave.3.right", "wave.3.left",
        "circle.hexagongrid.fill", "hexagon.fill", "hexagon",
        "triangle.fill", "triangle", "rectangle.fill", "rectangle",
        "pentagon.fill", "pentagon", "octagon.fill", "octagon",
        "circle.fill", "circle", "circle.dashed", "circle.dotted",
        "moon.dust.fill", "moon.dust", "sparkle"
    ]
}
