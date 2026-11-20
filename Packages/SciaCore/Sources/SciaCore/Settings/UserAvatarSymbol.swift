public enum UserAvatarSymbol: String, CaseIterable, Sendable {
    case person = "person.fill"
    case cat = "cat.fill"
    case dog = "dog.fill"
    case bird = "bird.fill"
    case fish = "fish.fill"
    case leaf = "leaf.fill"
    case flower = "camera.macro"
    case sun = "sun.max.fill"
    case moon = "moon.fill"
    case star = "star.fill"
    case heart = "heart.fill"
    case cup = "cup.and.saucer.fill"

    public var title: String {
        switch self {
        case .person: "人物"
        case .cat: "猫"
        case .dog: "犬"
        case .bird: "鳥"
        case .fish: "魚"
        case .leaf: "葉"
        case .flower: "花"
        case .sun: "太陽"
        case .moon: "月"
        case .star: "星"
        case .heart: "ハート"
        case .cup: "カップ"
        }
    }
}
