import Foundation

extension LanguageModule {
    public static let swedish = LanguageModule(
        id: "sv", name: "Swedish", nativeName: "Svenska", variety: "Sweden", locale: "sv-SE",
        greeting: "Hej!", greetingWord: "hej",
        speechGuidance: "Use clear standard Swedish (rikssvenska) pronunciation, as heard around Stockholm and Uppsala. Since the du-reformen, du is the natural form of address in almost every situation; use du with the learner. Accept Sweden's dialects and Finland Swedish without treating differences as errors, and do not treat imperfect pitch accent as an error.",
        writingGuidance: "Use standard Swedish spelling with å, ä and ö, and natural everyday word order. Accept common informal spellings from the learner without treating them as errors.",
        lemmaGuidance: "Give nouns with their singular indefinite article and verbs in the infinitive, for example en kopp, ett hus and att prata. Keep particle verbs such as att tycka om together. Preserve å, ä and ö.",
        teachingFocus: [
            "Greetings, introductions and short everyday chunks such as jag heter and en kaffe, tack.",
            "Simple questions, en and ett words, present tense and verb-second word order in main clauses.",
            "Connected stories, the past with preteritum and perfekt, and familiar everyday situations.",
            "Reasons and opinions, subordinate clauses with BIFF word order and natural connectors such as därför att and fastän.",
            "Nuanced discussion, idiomatic phrasing, register and the difference between lagom directness and politeness.",
            "Flexible advanced conversation with precise, natural Swedish."
        ],
        topicPlaceholder: "Fika, design, nature, life in Sweden…",
        lookupUnavailableReply: "Jag kunde inte kolla det just nu. Vi kan prata om ämnet generellt, om du vill.",
        themeOverrides: [
            "coffee": .init("coffee", "Fika?", "Something warm, something sweet", "cup.and.saucer", "Everyday", "Meet for fika at a Swedish café. Help the learner order coffee and a kanelbulle, then chat. Fika is a social pause, not just a drink; let the conversation slow down.", 0),
            "groceries": .init("groceries", "I saluhallen", "A little of everything", "basket", "Everyday", "Help the learner shop at a Swedish market hall (saluhall). Practise quantities, prices and polite questions, then ask what the learner likes to cook.", 2),
            "travel": .init("travel", "Nästa stopp", "A ticket to somewhere", "tram", "Everyday", "Plan a train trip in Sweden. Discuss routes and tickets without inventing current schedules.", 1),
            "weather": .init("weather", "Mörkt igen?", "A very Swedish chat", "cloud.rain", "Local life", "Talk about weather, clothing and outdoor plans through Sweden's dark winters and bright summers. Verify current forecasts before claiming them.", 1),
            "cabin": .init("cabin", "Sommarstuga weekend", "A quieter kind of day", "mountain.2", "Local life", "Plan a weekend at a sommarstuga: travel, food, a swim, walks and doing very little together. Allemansrätten shapes what is fine outdoors.", 2),
            "traditions": .init("traditions", "Lagom and lucia", "Small customs, big stories", "flag", "Local life", "Explore Swedish everyday customs with nuance: fika, lagom, du for everyone, lucia and midsommar. Avoid treating all Swedes as alike.", 2)
        ]
    )
}
