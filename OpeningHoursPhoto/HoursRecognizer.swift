//
//  HoursRecognizer.swift
//
//  Created by Bryce Cogswell on 4/5/21.
//

import VisionKit
import Vision

extension String.StringInterpolation {
	fileprivate mutating func appendInterpolation(_ time: Time) {
		appendLiteral(time.text)
	}
	fileprivate mutating func appendInterpolation(_ dash: Dash) {
		appendLiteral("-")
	}
	fileprivate mutating func appendInterpolation(_ token: Token) {
		switch token {
		case let .day(day):
			appendInterpolation(day)
		case let .time(time):
			appendInterpolation(time)
		case let .dash(dash):
			appendInterpolation(dash)
		case .endOfText:
			appendLiteral("")
		}
	}
}

extension CGRect {
	// 0..1 depending on the amount of overlap
	fileprivate func overlap(_ rect: CGRect) -> Float {
		let overlap = max(0.0, min(self.maxX,rect.maxX) - max(self.minX,rect.minX))
					* max(0.0, min(self.maxY,rect.maxY) - max(self.minY,rect.minY))
		let size1 = self.width * self.height
		let size2 = rect.width * rect.height
		return Float(overlap / (size1+size2-overlap))
	}
}

extension CharacterSet {
	fileprivate func contains(character: Character) -> Bool {
		for scaler in character.unicodeScalars {
			if self.contains(scaler) {
				return true
			}
		}
		return false
	}
}

extension Substring {
	fileprivate static func from(_ start: Substring, to: Substring) -> Substring {
		return start.base[ start.startIndex..<to.endIndex ]
	}
}

// return a list where all items are removed except the two with highest confidence (preserving their order)
extension Array {
	fileprivate func bestTwo(_ lessThan: (_ lhs: Self.Element, _ rhs: Self.Element) -> Bool) -> [Self.Element] {
		if self.count <= 2 {
			return self
		}
		var b0 = 0
		var b1 = 1
		for i in 2..<self.count {
			if lessThan( self[b0], self[i] ) {
				b0 = i
			} else if lessThan( self[b1], self[i]) {
				b1 = i
			}
		}
		if b0 < b1 {
			return [self[b0], self[b1]]
		} else {
			return [self[b1], self[b0]]
		}
	}
}

fileprivate typealias SubstringRectf = (string:Substring,rectf:(Range<String.Index>)->CGRect)
fileprivate typealias StringRect = (string:String, rect:CGRect)

// A version of Scanner that returns a rect for each string
fileprivate class RectScanner {

	let substring: Substring
	let scanner: Scanner
	let rectf:(Range<String.Index>)->CGRect

	static private let allLetters = CharacterSet.uppercaseLetters.union(CharacterSet.lowercaseLetters)

	init(substring: Substring, rectf:@escaping (Range<String.Index>)->CGRect) {
		self.substring = substring
		self.scanner = Scanner(string: String(substring))
		self.scanner.caseSensitive = false
		self.scanner.charactersToBeSkipped = nil
		self.rectf = rectf
	}

	var currentIndex: String.Index {
		get { scanner.currentIndex }
		set { scanner.currentIndex = newValue }
	}

	var string: String { return scanner.string }

	var isAtEnd: Bool {
		get { scanner.isAtEnd }
	}

	func result(_ sub:Substring) -> StringRect {
		let d1 = sub.distance(from: sub.base.startIndex, to: sub.startIndex )
		let d2 = sub.distance(from: sub.base.startIndex, to: sub.endIndex )
		let p1 = substring.index(substring.startIndex, offsetBy: d1)
		let p2 = substring.index(substring.startIndex, offsetBy: d2)
		let rect = rectf(p1..<p2)
		return (String(sub),rect)
	}

	func lastChar() -> StringRect {
		let last = scanner.string.index(before: scanner.string.endIndex)
		return result(scanner.string[last..<scanner.string.endIndex])
	}

	func scanString(_ string: String) -> StringRect? {
		let index = scanner.currentIndex
		if let _ = scanner.scanString(string) {
			return result(scanner.string[index..<scanner.currentIndex])
		}
		return nil
	}

	func scanWhitespace() -> StringRect? {
		let index = scanner.currentIndex
		if let _ = scanner.scanCharacters(from: CharacterSet.whitespacesAndNewlines) {
			return result(scanner.string[index..<scanner.currentIndex])
		}
		return nil
	}

	func scanUpToWhitespace() -> StringRect? {
		let index = scanner.currentIndex
		if let _ = scanner.scanUpToCharacters(from: CharacterSet.whitespacesAndNewlines) {
			return result(scanner.string[index..<scanner.currentIndex])
		}
		return nil
	}

	func scanInt() -> StringRect? {
		let index = scanner.currentIndex
		if let _ = scanner.scanInt() {
			return result(scanner.string[index..<scanner.currentIndex])
		}
		return nil
	}

	func scanWord(_ word: String) -> StringRect? {
		if let sub = scanString(word) {
			if sub.string.endIndex < scanner.string.endIndex {
				let c = scanner.string[sub.string.endIndex]
				if RectScanner.allLetters.contains(character: c) {
					// it's part of a larger word
					scanner.currentIndex = sub.string.startIndex
					return nil
				}
			}
			return sub
		}
		return nil
	}

	func scanAnyWord(_ words: [String]) -> StringRect? {
		for word in words {
			if let sub = scanWord(word) {
				return sub
			}
		}
		return nil
	}

	func remainder() -> String {
		return String(scanner.string[scanner.currentIndex...])
	}
}

// A version of Scanner that accepts an array of substrings and can extract rectangles for them
fileprivate class MultiScanner {

	let strings: [SubstringRectf]
	let scanners: [RectScanner]
	var scannerIndex: Int

	init(strings: [SubstringRectf]) {
		self.strings = strings
		self.scanners = strings.map { RectScanner(substring: $0.string, rectf:$0.rectf) }
		self.scannerIndex = 0
	}

	var currentIndex: (scanner:Int, index:String.Index) {
		get { (scannerIndex, scanners[scannerIndex].currentIndex) }
		set { scannerIndex = newValue.0
			scanners[scannerIndex].currentIndex = newValue.1
			for scan in scanners[(scannerIndex+1)...] {
				scan.currentIndex = scan.string.startIndex
			}
		}
	}

	var scanner:RectScanner {
		get {
			while scanners[scannerIndex].isAtEnd && scannerIndex+1 < scanners.count {
				scannerIndex += 1
			}
			return scanners[scannerIndex]
		}
	}

	var isAtEnd: Bool { return scanner.isAtEnd }

	func scanString(_ string: String) -> StringRect? {
		// we need to fudge an implied space at the break between two observations:
		if string == " " && scannerIndex > 0 && scanner.currentIndex == scanner.string.startIndex {
			// return rect for previous character
			let rect = scanners[scannerIndex-1].lastChar().rect
			return (" ",rect)
		}
		return scanner.scanString(string)
	}

	func scanWhitespace() -> StringRect? {
		var sub = scanner.scanWhitespace()
		// repeat in case we need to switch to next scanner
		if sub != nil {
			while let s = scanner.scanWhitespace() {
				sub = (sub!.string + s.string, sub!.rect.union(s.rect))
			}
		}
		return sub
	}

	func scanUpToWhitespace() -> StringRect? {
		return scanner.scanUpToWhitespace()
	}

	func scanInt() -> StringRect? {
		return scanner.scanInt()
	}

	func scanWord(_ word: String) -> StringRect? {
		return scanner.scanWord( word )
	}

	func scanAnyWord(_ words: [String]) -> StringRect? {
		return scanner.scanAnyWord(words)
	}

	func remainder() -> String {
		return scanners[scannerIndex...].map({$0.remainder()}).joined(separator: " ")
	}
}

fileprivate enum Day: String {
	case Mo = "Mo"
	case Tu = "Tu"
	case We = "We"
	case Th = "Th"
	case Fr = "Fr"
	case Sa = "Sa"
	case Su = "Su"

	static let english = [	Day.Mo: ["monday", 		"mo", "mon"],
							Day.Tu: ["tuesday", 	"tu", "tue"],
							Day.We: ["wednesday",	"we", "wed"],
							Day.Th: ["thursday", 	"th", "thu", "thur"],
							Day.Fr: ["friday", 		"fr", "fri"],
							Day.Sa: ["saturday", 	"sa", "sat"],
							Day.Su: ["sunday", 		"su", "sun"]
	]
	static let german = [	Day.Mo: ["montag", 		"mo", "mon"],
							Day.Tu: ["dienstag", 	"di"],
							Day.We: ["mittwoch",	"mi"],
							Day.Th: ["donnerstag", 	"do", "don"],
							Day.Fr: ["freitag", 	"fr"],
							Day.Sa: ["samstag", 	"sa", "sam"],
							Day.Su: ["sonntag",		"so", "son"]
	]

	static func scan(scanner:MultiScanner, language:HoursRecognizer.Language) -> (day:Self, rect:CGRect, confidence:Float)? {
		let dict = { () -> [Day:[String]] in
			switch language {
			case .en: return english
			case .de: return german
			}
		}()
		for (day,strings) in dict {
			if let s = scanner.scanAnyWord(strings) {
				return (day,s.rect,Float(s.string.count))
			}
		}
		return nil
	}
}

fileprivate struct Time {
	let text: String

	init(hour: Int, minute:Int) {
		self.text = String(format: "%02d:%02d", hour, minute)
	}

	static func scan(scanner: MultiScanner) -> (time:Self, rect:CGRect, confidence:Float)? {

		let index = scanner.currentIndex
		guard let hour = scanner.scanInt() else { return nil }
		if let iHour = Int(hour.string),
		   iHour >= 0 && iHour <= 24
		{
			let index2 = scanner.currentIndex
			if scanner.scanString(":") != nil || scanner.scanString(".") != nil || scanner.scanString(" ") != nil,
			   let minute = scanner.scanInt(),
			   minute.string.count == 2,
			   minute.string >= "00" && minute.string < "60"
			{
				_ = scanner.scanWhitespace()
				if let am = scanner.scanString("AM") {
					return (Time(hour: iHour%12, minute: Int(minute.string)!),
							hour.rect.union(am.rect),
							8.0)
				}
				if let pm = scanner.scanString("PM") {
					return (Time(hour: (iHour%12)+12, minute: Int(minute.string)!),
							hour.rect.union(pm.rect),
							8.0)
				}
				return (Time(hour: iHour, minute: Int(minute.string)!),
						hour.rect.union(minute.rect),
						6.0)
			}
			scanner.currentIndex = index2

			_ = scanner.scanWhitespace()
			if let am = scanner.scanString("AM") {
				return (Time(hour: iHour%12, minute: 0),
						hour.rect.union(am.rect),
						4.0)
			}
			if let pm = scanner.scanString("PM") {
				return (Time(hour: (iHour%12)+12, minute: 0),
						hour.rect.union(pm.rect),
						4.0)
			}
			return (Time(hour: iHour, minute: 0),
					hour.rect,
					1.0)
		}
		scanner.currentIndex = index
		return nil
	}
}

fileprivate struct Dash {
	static func scan(scanner: MultiScanner, language: HoursRecognizer.Language) -> (Self,CGRect,Float)? {
		let through = { () -> String in
			switch language {
			case .en: return "to"
			case .de: return "bis"
			}}()

		if let s = scanner.scanString("-") ?? scanner.scanWord(through) {
			return (Dash(), s.rect, Float(s.string.count))
		}
		return nil
	}
}

fileprivate typealias SubstringRectConfidence = (substring:Substring, rect:CGRect, rectf:(Range<String.Index>)->CGRect, confidence:Float)
fileprivate typealias TokenRectConfidence = (token:Token, rect:CGRect, confidence:Float)

fileprivate enum Token : Equatable {
	case time(Time)
	case day(Day)
	case dash(Dash)
	case endOfText

	static func == (lhs: Token, rhs: Token) -> Bool {
		return "\(lhs)" == "\(rhs)"
	}

	func isDay() -> Bool {
		switch self {
		case .day:
			return true
		default:
			return false
		}
	}
	func isTime() -> Bool {
		switch self {
		case .time:
			return true
		default:
			return false
		}
	}
	func isDash() -> Bool {
		switch self {
		case .dash:
			return true
		default:
			return false
		}
	}

	static func scan(scanner: MultiScanner, language: HoursRecognizer.Language) -> TokenRectConfidence? {
		if let (day,rect,confidence) = Day.scan(scanner: scanner, language: language) {
			return (.day(day),rect,confidence)
		}
		if let (time,rect,confidence) = Time.scan(scanner: scanner) {
			return (.time(time),rect,confidence)
		}
		if let (dash,rect,confidence) = Dash.scan(scanner: scanner, language: language) {
			return (.dash(dash),rect,confidence)
		}
		return nil
	}
}

public class HoursRecognizer: ObservableObject {

	private var resultHistory = [String:Int]()
	@Published private(set) var finished = false {
		willSet {
			objectWillChange.send()
		}
	}

	@Published public var language: Language = .en
	@Published var text = "" {
		willSet {
			objectWillChange.send()
		}
	}

	init() {
	}

	public enum Language: String, CaseIterable, Identifiable {
		public var id: String { get { self.rawValue } }
		case en = "en"
		case de = "de"
	}

	public func restart() {
		self.text = ""
		self.resultHistory.removeAll()
		self.finished = false
	}

	private class func tokensForString(_ strings: [SubstringRectConfidence], language: Language) -> [TokenRectConfidence] {
		var list = [TokenRectConfidence]()

		let scanner = MultiScanner(strings: strings.map { return ($0.substring, $0.rectf)} )
		_ = scanner.scanWhitespace()
		while !scanner.isAtEnd {
			if let token = Token.scan(scanner: scanner, language: language) {
				list.append( token )
			} else {
				// skip to next token
				_ = scanner.scanUpToWhitespace()
			}
			_ = scanner.scanWhitespace()
		}
		return list
	}

	// takes an array of image observations and returns blocks of text along with their locations
	private class func stringsForImage(observations: [VNRecognizedTextObservation], transform:CGAffineTransform) -> [SubstringRectConfidence] {
		var wordList = [SubstringRectConfidence]()
		for observation in observations {
			guard let candidate = observation.topCandidates(1).first else { continue }
			// Each observation can contain text in disconnected parts of the screen,
			// so we tokenize the string and extract the screen location of each token
			let rectf:(Range<String.Index>)->CGRect = {
				let rect = try! candidate.boundingBox(for: $0)!.boundingBox
				let rect2 = rect.applying(transform)
				return rect2
			}
			let words = candidate.string.split(separator: " ")
			let words2 = words.map({ word -> SubstringRectConfidence in
				// Previous call returns tokens with substrings, which we can pass to candidate to get the rect
				let rect = rectf( word.startIndex ..< word.endIndex )
				return (word, rect, rectf, candidate.confidence)
			})
			wordList += words2
		}
		return wordList
	}

	// splits observed text text blocks into lines of text, sorted left-to-right and top-to-bottom
	private class func getStringLines( _ allStrings: [SubstringRectConfidence] ) -> [[SubstringRectConfidence]] {
		var lines = [[SubstringRectConfidence]]()

		var list = allStrings

		while !list.isEmpty {

			// get highest confidence string
			let bestIndex = list.indices.max(by: {list[$0].confidence < list[$1].confidence})!
			let best = list[ bestIndex ]
			list.remove(at: bestIndex)
			var lineStrings = [best]

			// find tokens to left
			var prev = best
			while true {
				let strings = list.indices.filter({ list[$0].rect.maxX <= prev.rect.minX && (prev.rect.minY...prev.rect.maxY).contains( list[$0].rect.midY )})
				if strings.isEmpty { break }
				let closest = strings.min(by: {prev.rect.minX - list[$0].rect.maxX < prev.rect.minX - list[$1].rect.maxX})!
				prev = list[closest]
				lineStrings.insert( prev, at: 0)
				list.remove(at: closest)
			}

			// find tokens to right
			prev = best
			while true {
				let strings = list.indices.filter({ list[$0].rect.minX >= prev.rect.maxX && (prev.rect.minY...prev.rect.maxY).contains( list[$0].rect.midY )})
				if strings.isEmpty { break }
				let closest = strings.min(by: {list[$0].rect.minX - prev.rect.maxX < list[$1].rect.minX - prev.rect.maxX})!
				prev = list[closest]
				lineStrings.append( prev )
				list.remove(at: closest)
			}

			// save the line of strings
			lines.append( lineStrings )
		}

		// sort lines top-to-bottom
		lines.sort(by: {$0.first!.rect.minY < $1.first!.rect.minY} )

		return lines
	}

	private class func tokenLinesForStringLines( _ stringLines: [[SubstringRectConfidence]], language: Language) -> [[TokenRectConfidence]] {
		// convert lines of strings to lines of tokens
		let tokenLines = stringLines.compactMap { line -> [TokenRectConfidence]? in
			let tokens = HoursRecognizer.tokensForString( line, language: language )
			return tokens.isEmpty ? nil : tokens
		}
		return tokenLines
	}

	// split the lines so each sequence of days or times is in its own group
	private class func homogeneousSequencesForTokenLines( _ tokenLines: [[TokenRectConfidence]]) -> [[TokenRectConfidence]] {
		var tokenSets = [[TokenRectConfidence]]()
		for line in tokenLines {
			guard let first = line.indices.first(where: {!line[$0].token.isDash()}) else { continue }
			tokenSets.append([line[first]] )
			var prevDash: TokenRectConfidence? = nil

			for token in line[(first+1)...] {
				if token.token.isDash() {
					prevDash = token
				} else if token.token.isDay() == tokenSets.last?.first?.token.isDay() ||
						  token.token.isTime() == tokenSets.last?.first?.token.isTime()
				{
					if let dash = prevDash {
						tokenSets[tokenSets.count-1].append(dash)
						prevDash = nil
					}
					tokenSets[tokenSets.count-1].append(token)
				} else {
					prevDash = nil
					tokenSets.append([token])
				}
			}
			tokenSets.append([])
		}
		tokenSets.removeAll(where: { $0.isEmpty })

		return tokenSets
	}


	// if a sequence has multiple days then take only the best 2
	private class func GoodDaysForTokenSequences( _ tokenSet: [TokenRectConfidence]) -> [TokenRectConfidence]? {
		// return tokenSets.map( { return $0.first!.token.isDay() ? $0.bestTwo( {$0.confidence < $1.confidence} ) : $0 })
		return tokenSet
	}

	// if a sequence has multiple times then take only the best even number
	private class func GoodTimesForTokenSequences( _ tokenSet: [TokenRectConfidence]) -> [TokenRectConfidence]? {
		var list = tokenSet
		var pairs = [(TokenRectConfidence,TokenRectConfidence)]()

		// pull out dash-seperated pairs
		while let dash = list.indices.first(where: {list[$0].token.isDash()}) {
			if dash > 1 {
				var priors = Array(list[0..<dash-1])
				if priors.count % 2 == 1 {
					let worst = priors.indices.min(by: {priors[$0].confidence < priors[$1].confidence})!
					priors.remove(at: worst)
				}
				while !priors.isEmpty {
					pairs.append( (priors[0], priors[1] ) )
					priors.removeSubrange(0...1)
				}
			}

			pairs.append( (list[dash-1], list[dash+1]) )
			list.removeSubrange( 0...dash+1 )
		}
		if list.count % 2 == 1 {
			let worst = list.indices.min(by: {list[$0].confidence < list[$1].confidence})!
			list.remove(at: worst)
		}
		while !list.isEmpty {
			pairs.append( (list[0], list[1] ) )
			list.removeSubrange(0...1)
		}

		// look for suspicious pairs
		pairs.removeAll(where: {"\($0.0.token)" == "00:00" && "\($0.1.token)" == "00:00"})

		return pairs.count > 0 ? pairs.flatMap({ [$0.0,$0.1] }) : nil
	}

	// convert lists of tokens to the final string
	private class func hoursStringForTokens(_ tokenLines: [[TokenRectConfidence]]) -> String {
		var days = [TokenRectConfidence]()
		var times = [TokenRectConfidence]()
		var result = ""

		for line in tokenLines + [[(.endOfText,CGRect(),0.0)]] {
			// each line should be 1 or more days, then 2 or more hours
			for token in line  {
				switch token.token {
				case .day, .endOfText:
					if times.count >= 2 {
						// output preceding days/times
						if days.count > 0 {
							if days.count == 2 {
								// treat as a range of days
								result += "\(days[0].token)-\(days[1].token)"
							} else {
								// treat as a list of days
								result += days.reduce("", { result, next in
									return result == "" ? "\(next.token)" : result + "," + "\(next.token)"
								})
							}
							result += " "
						}

						for index in stride(from: 0, to: times.count, by: 2) {
							result += "\(times[index].token)-\(times[index+1].token),"
						}
						result += " "
					}
					if times.count > 0 {
						times = []
						days = []
					}
					days.append(token)

				case .time:
					times.append(token)
					break
				case .dash:
					break
				}
			}
		}
		if result.hasSuffix(", ") {
			result = String(result.dropLast(2))
		}
		return result
	}

	private func updateWithObservations(observations: [VNRecognizedTextObservation],
										transform: CGAffineTransform,
										camera: CameraView?)
	{
		if finished {
			return
		}

		#if false
		let raw = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
		Swift.print("\"\(raw)\"")
		#endif

		// get strings and locations
		let strings = HoursRecognizer.stringsForImage(observations: observations, transform: transform)

		#if false
		print("")
		print("strings:")
		for s in strings {
			print("\(s.substring): \(s.rect)")
		}
		#endif

		// split into lines of text
		let stringLines = HoursRecognizer.getStringLines( strings )

		#if true
		print("")
		print("string lines:")
		for line in stringLines {
			let s1 = line.map({$0.substring}).joined(separator: " ")
			let s2 = line.map({"\($0.confidence)"}).joined(separator: " ")
			print("\(s1): \(s2)")
		}
		#endif

		// convert strings to tokens
		var tokenSets = HoursRecognizer.tokenLinesForStringLines( stringLines, language: self.language )

		#if true
		print("")
		print("token lines:")
		for s in tokenSets {
			let s1 = s.map({ "\($0.token)"}).joined(separator: " ")
			let s2 = s.map({ "\($0.confidence)"}).joined(separator: " ")
			print("\(s1): \(s2)")
		}
		#endif

		tokenSets = HoursRecognizer.homogeneousSequencesForTokenLines( tokenSets )

		// get homogeneous day/time sets
		tokenSets = tokenSets.compactMap {
			if $0.first!.token.isDay() {
				return HoursRecognizer.GoodDaysForTokenSequences( $0 )
			} else {
				return HoursRecognizer.GoodTimesForTokenSequences( $0 )
			}
		}

		#if false
		print("")
		for line in tokenSets {
			let s1 = line.map( { "\($0.token)" }).joined(separator: " ")
			let s2 = line.map( { "\(Float(Int(100.0*$0.confidence))/100.0)" }).joined(separator: " ")
			print("\(s1): \(s2)")
		}
		#endif

		// convert the final sets of tokens to a single stream
		let resultString = HoursRecognizer.hoursStringForTokens( tokenSets )

		// show the selected tokens in the video feed
		let invertedTransform = transform.inverted()
		let tokenBoxes = tokenSets.joined().map({$0.rect.applying(invertedTransform)})
		camera?.addBoxes(boxes: tokenBoxes, color: UIColor.green)

		#if false
		print("\(text)")
		#endif

		if resultString != "" {
			let count = (resultHistory[resultString] ?? 0) + 1
			resultHistory[resultString] = count

			let best = resultHistory.max { $0.value < $1.value }!

			if Thread.isMainThread {
				self.text = best.key
				self.finished = best.value >= 5
			} else {
				DispatchQueue.main.async {
					self.text = best.key
					self.finished = best.value >= 5
				}
			}
		}
	}

	func updateWithLiveObservations(observations: [VNRecognizedTextObservation], camera: CameraView?) {
		self.updateWithObservations(observations: observations,
									transform: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: 1),
									   camera: camera)
	}

	func setImage(image: CGImage, isRotated: Bool) {
		self.restart()

//		let rotationTransform = CGAffineTransform(translationX: 0, y: 1).rotated(by: -CGFloat.pi / 2)

		let transform = isRotated ? CGAffineTransform(scaleX: 1.0, y: -1.0).rotated(by: -CGFloat.pi / 2)
									: CGAffineTransform.identity

		let request = VNRecognizeTextRequest(completionHandler: { (request, error) in
			guard error == nil,
				  let observations = request.results as? [VNRecognizedTextObservation] else { return }
			self.updateWithObservations(observations: observations, transform: transform, camera:nil)
		})
		request.recognitionLevel = .accurate
//		request.customWords = ["AM","PM"]
//		request.usesLanguageCorrection = true
		let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
		try? requestHandler.perform([request])
	}
}

#if targetEnvironment(macCatalyst)
class BulkProcess {
	init() {
	}

	func processFile(path:String) {
		do {
			let userDirectory = try FileManager.default.url(for: FileManager.SearchPathDirectory.downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
			let filePath = userDirectory.appendingPathComponent(path)
			let recognizer = HoursRecognizer()
			guard let image = UIImage(contentsOfFile: filePath.path),
				  let cgImage = image.cgImage else { return }
			recognizer.setImage(image: cgImage, isRotated: true)
			print("\"\(filePath.lastPathComponent)\" => \"\(recognizer.text)\",")
		} catch {
			print(error.localizedDescription)
		}
	}

	func processFolder(path:String) {
		do {
			let userDirectory = try FileManager.default.url(for: FileManager.SearchPathDirectory.downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
			let imageDirectory = userDirectory.appendingPathComponent(path)
			let fileList = try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil, options: [])
			let recognizer = HoursRecognizer()
			for fileName in fileList {
//				print("\(fileName.lastPathComponent):")
				guard let image = UIImage(contentsOfFile: fileName.path),
					  let cgImage = image.cgImage else { continue }
				recognizer.setImage(image: cgImage, isRotated: true)
				print("\"\(fileName.lastPathComponent)\" => \"\(recognizer.text)\",")
			}
		} catch {
			print(error.localizedDescription)
		}
	}
}
#endif
