import Foundation

/// Generates `adjective-noun` device names such as `amber-falcon`.
///
/// The lists are curated rather than read from `/usr/share/dict/words`: that file is Webster's 2nd (1934)
/// and mostly yields obscure or unfortunate words. 200 x 200 = 40,000 combinations, which is plenty for a
/// pool of tens of devices; a third word would only make names harder to type.
public enum NameGenerator {
    public static func generate<G: RandomNumberGenerator>(avoiding taken: Set<String>, using generator: inout G) -> String {
        for _ in 0..<1_000 {
            let name = "\(adjectives.randomElement(using: &generator)!)-\(nouns.randomElement(using: &generator)!)"
            if !taken.contains(name) { return name }
        }
        // Unreachable in practice; keeps the function total if the pool ever gets absurdly large.
        return
            "\(adjectives.randomElement(using: &generator)!)-\(nouns.randomElement(using: &generator)!)-\(UInt16.random(in: 0...UInt16.max, using: &generator))"
    }

    public static func generate(avoiding taken: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(avoiding: taken, using: &generator)
    }

    static let adjectives: [String] = [
        "amber", "ample", "arctic", "azure", "balmy", "bold", "brave", "breezy", "bright", "brisk",
        "bronze", "bonny", "calm", "candid", "cheery", "chill", "civic", "clear", "clever", "cobalt",
        "cosmic", "cozy", "crisp", "curly", "dapper", "daring", "dawn", "deft", "dewy", "dusky",
        "eager", "early", "easy", "ebony", "elder", "epic", "fair", "fancy", "fast", "fiery",
        "fleet", "fluffy", "fond", "frank", "festive", "fresh", "frosty", "fuzzy", "gentle", "giant",
        "glad", "gleamy", "glossy", "golden", "grand", "green", "happy", "hardy", "hazel", "hearty",
        "honest", "humble", "icy", "radiant", "indigo", "ivory", "jade", "jazzy", "jolly", "jumbo",
        "keen", "kind", "lemon", "light", "lilac", "limber", "little", "lively", "lofty", "loyal",
        "lucky", "lunar", "lush", "magic", "maple", "marble", "mellow", "merry", "mighty", "mild",
        "minty", "misty", "modest", "mossy", "neat", "nimble", "noble", "north", "oaken", "ocean",
        "olive", "opal", "orange", "patient", "peachy", "pearly", "pine", "plucky", "plush", "polar",
        "polite", "proud", "quick", "quiet", "rapid", "rare", "ready", "regal", "rocky", "rosy",
        "royal", "ruby", "rustic", "sandy", "satin", "scarlet", "shiny", "silent", "silky", "silver",
        "simple", "sleek", "smart", "smooth", "snowy", "snug", "solar", "solid", "sonic", "spicy",
        "spry", "starry", "steady", "stellar", "stormy", "sturdy", "sunny", "super", "swift", "tall",
        "tame", "tawny", "teal", "tender", "tidy", "tiny", "topaz", "tranquil", "true", "tulip",
        "upbeat", "urban", "valiant", "velvet", "vivid", "warm", "wavy", "wild", "windy", "wise",
        "witty", "woolly", "young", "zesty", "zippy", "agile", "alpine", "aqua", "autumn", "basic",
        "beige", "blithe", "bouncy", "sunlit", "bubbly", "cedar", "cherry", "citrus", "coral", "crimson",
        "dreamy", "dusty", "fabled", "feisty", "floral", "gusty", "hidden", "jovial", "kindly", "lavish",
    ]

    static let nouns: [String] = [
        "acorn", "alpaca", "anchor", "apple", "arrow", "aspen", "atlas", "badger", "bagel", "banjo",
        "beacon", "beaver", "birch", "bison", "blossom", "bobcat", "breeze", "brook", "bucket", "button",
        "cactus", "camel", "canyon", "cedar", "comet", "condor", "cookie", "coral", "cougar", "coyote",
        "crane", "cricket", "dahlia", "daisy", "delta", "dingo", "dolphin", "donut", "dragon", "eagle",
        "ember", "falcon", "fern", "ferret", "finch", "fjord", "flamingo", "forest", "fox", "gazelle",
        "gecko", "geyser", "glacier", "goose", "grove", "harbor", "hawk", "hazel", "hedgehog", "heron",
        "hippo", "honey", "husky", "ibis", "iceberg", "iguana", "island", "jackal", "jaguar", "jasmine",
        "jelly", "jet", "kayak", "kestrel", "kettle", "kiwi", "koala", "lagoon", "lantern", "lark",
        "lemur", "lily", "lion", "llama", "lobster", "lotus", "lynx", "magnet", "mango", "maple",
        "marlin", "meadow", "meteor", "mink", "mole", "moose", "moth", "muffin", "narwhal", "nebula",
        "newt", "nutmeg", "oak", "oasis", "ocelot", "octopus", "orbit", "orca", "osprey", "otter",
        "owl", "panda", "panther", "parrot", "peach", "pebble", "pelican", "penguin", "pepper", "petal",
        "pigeon", "pine", "planet", "plum", "pony", "poppy", "prairie", "puffin", "puma", "quail",
        "quartz", "rabbit", "raccoon", "radish", "raven", "reef", "river", "robin", "rocket", "salmon",
        "sapling", "seal", "shark", "sparrow", "spruce", "squid", "star", "stork", "summit", "swan",
        "tapir", "thistle", "tiger", "toucan", "trout", "tulip", "tundra", "turtle", "valley", "violet",
        "walnut", "walrus", "willow", "wombat", "wren", "yak", "zebra", "zephyr", "acacia", "aurora",
        "basil", "beetle", "bramble", "canary", "cobra", "cosmos", "dune", "elk", "galaxy", "garnet",
        "ginger", "gopher", "harp", "ivy", "juniper", "kelp", "kite", "lichen", "marmot", "mesa",
        "minnow", "nectar", "orchid", "papaya", "quokka", "sequoia", "sloth", "tamarin", "yeti", "zinnia",
    ]
}
