import Foundation

/// Picks a computer player's move.
///
/// The interesting part of Atlas is not recall but the letter economy: every
/// place you play hands the next player a letter, and some letters are far
/// poorer than others.  A hard bot spends its turn looking for the reply that
/// leaves its opponent the fewest options, while an easy bot just plays
/// something it "knows" and often fumbles.
public struct Bot {
    public let atlas: Atlas
    public let difficulty: BotDifficulty

    public init(atlas: Atlas, difficulty: BotDifficulty) {
        self.atlas = atlas
        self.difficulty = difficulty
    }

    /// How many candidates a strategic bot examines.  Scoring every option for
    /// a common letter would mean thousands of index lookups per turn for no
    /// gain in play strength.
    private static let searchWidth = 60

    /// At or below this many options a letter counts as starved, and the bot
    /// may reach below its usual fame tier — see `BotDifficulty.recallRate`.
    private static let starvedThreshold = 4

    /// Returns the place to play, or `nil` to run the clock out.
    ///
    /// `card`, when the table is playing them, is a second thing to want: a
    /// move that meets it scores several times over, so a strong bot goes
    /// looking for one and a weak bot often does not notice.  Under
    /// `mustMeetCard` it stops being a preference — a bot that cannot meet the
    /// card has no move at all, the same as a player who cannot think of one.
    public func choose(letter: Character, used: Set<Int>, minFame: Int,
                       card: Card? = nil, mustMeetCard: Bool = false,
                       rng: inout SeededRNG) -> String? {
        let floor = max(minFame, difficulty.minFame)
        var options = atlas.candidates(startingWith: letter, minFame: floor, excluding: used)

        // The famous tier is threadbare on X, Q, O, Y and Z.  Conceding
        // outright whenever the chain lands there would make easy bots lose in
        // exactly the same way every game, so instead they dig for something
        // obscure and only sometimes come up with it.
        if options.count < Bot.starvedThreshold {
            let wider = atlas.candidates(startingWith: letter, minFame: minFame,
                                         excluding: used)
            if wider.count > options.count,
               Double.random(in: 0...1, using: &rng) < difficulty.recallRate {
                options = wider
            }
        }
        guard !options.isEmpty else { return nil }

        if let card {
            let meeting = options.filter {
                card.accepts(text: $0.text, place: atlas.place($0.placeID))
            }
            if mustMeetCard {
                // A forced card is not advice.  Digging below the fame tier is
                // allowed here even for an easy bot: refusing to answer a rule
                // the table has agreed to reads as the bot being broken.
                if meeting.isEmpty {
                    let wider = atlas.candidates(startingWith: letter, minFame: minFame,
                                                 excluding: used)
                        .filter { card.accepts(text: $0.text, place: atlas.place($0.placeID)) }
                    guard !wider.isEmpty else { return nil }
                    options = wider
                } else {
                    options = meeting
                }
            } else if !meeting.isEmpty,
                      Double.random(in: 0...1, using: &rng) < difficulty.cardRate {
                options = meeting
            }
        }

        if difficulty.blunderRate > 0,
           Double.random(in: 0...1, using: &rng) < difficulty.blunderRate {
            return nil
        }

        let playsStrategically = Double.random(in: 0...1, using: &rng) < difficulty.strategyRate
        guard playsStrategically else { return weightedPick(options, rng: &rng)?.text }

        // Score by how little the reply letter leaves the opponent.  `used` is
        // updated hypothetically so a place cannot count itself as a reply.
        var best: (surface: Atlas.Surface, score: Int)?
        for candidate in options.prefix(Bot.searchWidth) {
            var after = used
            after.insert(candidate.placeID)
            let replies = atlas.replyCount(for: candidate.last, minFame: minFame,
                                           excluding: after)
            if best == nil || replies < best!.score {
                best = (candidate, replies)
            }
            if replies == 0 { break }   // an outright kill, stop looking
        }
        return best?.surface.text ?? options.first?.text
    }

    /// Favours famous places so bots sound like people, without being predictable.
    private func weightedPick(_ options: [Atlas.Surface],
                              rng: inout SeededRNG) -> Atlas.Surface? {
        guard !options.isEmpty else { return nil }
        // `options` is fame-descending; a triangular pick over the top slice
        // keeps play recognisable while still varying between games.
        let window = min(options.count, 40)
        let a = Int(rng.next() % UInt64(window))
        let b = Int(rng.next() % UInt64(window))
        return options[min(a, b)]
    }
}
