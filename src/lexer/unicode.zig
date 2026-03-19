//! Unicode utilities for the ZTS lexer.
//!
//! ECMAScript 식별자에 사용할 수 있는 유니코드 문자를 판별한다.
//! - ID_Start: 식별자 시작 문자 (Unicode Lu, Ll, Lt, Lm, Lo, Nl + $ + _)
//! - ID_Continue: 식별자 계속 문자 (ID_Start + Mn, Mc, Nd, Pc + ZWNJ + ZWJ)
//!
//! UTF-8 디코딩 유틸리티도 포함.
//!
//! 참고: https://tc39.es/ecma262/#sec-names-and-keywords

const std = @import("std");

/// UTF-8 바이트 시퀀스에서 코드포인트 하나를 디코딩한다.
/// 반환: (코드포인트, 소비한 바이트 수). 유효하지 않으면 (0xFFFD, 1).
pub fn decodeUtf8(bytes: []const u8) struct { codepoint: u21, len: u3 } {
    if (bytes.len == 0) return .{ .codepoint = 0, .len = 0 };

    const b0 = bytes[0];

    // ASCII (0xxxxxxx)
    if (b0 < 0x80) return .{ .codepoint = b0, .len = 1 };

    // 2바이트 (110xxxxx 10xxxxxx)
    if (b0 >= 0xC0 and b0 < 0xE0) {
        if (bytes.len < 2) return .{ .codepoint = 0xFFFD, .len = 1 };
        const cp = (@as(u21, b0 & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F);
        return .{ .codepoint = cp, .len = 2 };
    }

    // 3바이트 (1110xxxx 10xxxxxx 10xxxxxx)
    if (b0 >= 0xE0 and b0 < 0xF0) {
        if (bytes.len < 3) return .{ .codepoint = 0xFFFD, .len = 1 };
        const cp = (@as(u21, b0 & 0x0F) << 12) |
            (@as(u21, bytes[1] & 0x3F) << 6) |
            @as(u21, bytes[2] & 0x3F);
        return .{ .codepoint = cp, .len = 3 };
    }

    // 4바이트 (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
    if (b0 >= 0xF0 and b0 < 0xF8) {
        if (bytes.len < 4) return .{ .codepoint = 0xFFFD, .len = 1 };
        const cp = (@as(u21, b0 & 0x07) << 18) |
            (@as(u21, bytes[1] & 0x3F) << 12) |
            (@as(u21, bytes[2] & 0x3F) << 6) |
            @as(u21, bytes[3] & 0x3F);
        return .{ .codepoint = cp, .len = 4 };
    }

    return .{ .codepoint = 0xFFFD, .len = 1 };
}

/// ECMAScript IdentifierStart 문자인지 판별한다.
/// Unicode ID_Start + $ + _ + \ (유니코드 이스케이프 시작)
pub fn isIdentifierStart(cp: u21) bool {
    // ASCII fast path
    if (cp < 0x80) {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            cp == '_' or cp == '$';
    }

    // Unicode ID_Start 범위 (간소화된 버전)
    // 전체 Unicode 테이블 대신 주요 범위만 커버.
    // 정확한 판별은 추후 생성된 테이블로 교체 가능.
    return isUnicodeIdStart(cp);
}

/// ECMAScript IdentifierPart 문자인지 판별한다.
/// Unicode ID_Continue + $ + ZWNJ (U+200C) + ZWJ (U+200D)
pub fn isIdentifierContinue(cp: u21) bool {
    // ASCII fast path
    if (cp < 0x80) {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or
            cp == '_' or cp == '$';
    }

    // ZWNJ, ZWJ
    if (cp == 0x200C or cp == 0x200D) return true;

    return isUnicodeIdContinue(cp);
}

/// Unicode ID_Start 범위 판별 (간소화).
/// 주요 유니코드 블록만 커버. 전체 테이블은 추후 Unicode Data에서 생성.
fn isUnicodeIdStart(cp: u21) bool {
    // Latin Extended
    if (cp >= 0x00C0 and cp <= 0x024F) return cp != 0x00D7 and cp != 0x00F7;
    // Greek and Coptic
    if (cp >= 0x0370 and cp <= 0x03FF) return true;
    // Cyrillic
    if (cp >= 0x0400 and cp <= 0x04FF) return true;
    // Armenian
    if (cp >= 0x0530 and cp <= 0x058F) return true;
    // Hebrew
    if (cp >= 0x0590 and cp <= 0x05FF) return true;
    // Arabic
    if (cp >= 0x0600 and cp <= 0x06FF) return true;
    // Devanagari
    if (cp >= 0x0900 and cp <= 0x097F) return true;
    // Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam
    if (cp >= 0x0980 and cp <= 0x0DFF) return true;
    // Syriac
    if (cp >= 0x0700 and cp <= 0x074F) return true;
    // Thaana
    if (cp >= 0x0780 and cp <= 0x07BF) return true;
    // NKo
    if (cp >= 0x07C0 and cp <= 0x07FF) return true;
    // Thai
    if (cp >= 0x0E00 and cp <= 0x0E7F) return true;
    // Lao
    if (cp >= 0x0E80 and cp <= 0x0EFF) return true;
    // Tibetan
    if (cp >= 0x0F00 and cp <= 0x0FFF) return true;
    // Myanmar
    if (cp >= 0x1000 and cp <= 0x109F) return true;
    // Georgian
    if (cp >= 0x10A0 and cp <= 0x10FF) return true;
    // Hangul Jamo
    if (cp >= 0x1100 and cp <= 0x11FF) return true;
    // Ethiopic
    if (cp >= 0x1200 and cp <= 0x137F) return true;
    // Cherokee
    if (cp >= 0x13A0 and cp <= 0x13FF) return true;
    // Unified Canadian Aboriginal Syllabics
    if (cp >= 0x1400 and cp <= 0x167F) return true;
    // Mongolian
    if (cp >= 0x1800 and cp <= 0x18AF) return true;
    // Khmer
    if (cp >= 0x1780 and cp <= 0x17FF) return true;
    // Latin Extended Additional
    if (cp >= 0x1E00 and cp <= 0x1EFF) return true;
    // Greek Extended
    if (cp >= 0x1F00 and cp <= 0x1FFF) return true;
    // CJK Radicals Supplement, Kangxi Radicals, CJK Symbols
    if (cp >= 0x2E80 and cp <= 0x2FDF) return true;
    // Bopomofo
    if (cp >= 0x3100 and cp <= 0x312F) return true;
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return true;
    // Katakana, Hiragana
    if (cp >= 0x3040 and cp <= 0x30FF) return true;
    // CJK Extension B
    if (cp >= 0x20000 and cp <= 0x2A6DF) return true;

    // Other_ID_Start (ECMAScript 특별 예외 문자)
    // U+1885..U+1886 (Mongolian), U+2118 (℘), U+212E (℮), U+309B..U+309C (゛゜)
    if (cp == 0x1885 or cp == 0x1886 or cp == 0x2118 or cp == 0x212E or
        cp == 0x309B or cp == 0x309C) return true;

    // Letter Number (Nl) — 로마 숫자 Ⅰ-ⅿ 등
    if (cp >= 0x2160 and cp <= 0x2188) return true;

    return false;
}

/// Unicode ID_Continue 범위 판별 (간소화).
/// ID_Start + Mn + Mc + Nd + Pc + Other_ID_Continue + ZWNJ + ZWJ
fn isUnicodeIdContinue(cp: u21) bool {
    if (isUnicodeIdStart(cp)) return true;

    // Combining marks (Mn, Mc) — 넓은 범위 커버
    if (cp >= 0x0300 and cp <= 0x036F) return true; // Combining Diacritical Marks
    if (cp >= 0x0483 and cp <= 0x0487) return true; // Cyrillic combining
    if (cp >= 0x0591 and cp <= 0x05BD) return true; // Hebrew combining
    if (cp >= 0x05BF and cp == 0x05BF) return true;
    if (cp >= 0x05C1 and cp <= 0x05C2) return true;
    if (cp >= 0x05C4 and cp <= 0x05C5) return true;
    if (cp == 0x05C7) return true;
    if (cp >= 0x0610 and cp <= 0x061A) return true; // Arabic combining
    if (cp >= 0x064B and cp <= 0x0669) return true; // Arabic combining + digits
    if (cp == 0x0670) return true;
    if (cp >= 0x06D6 and cp <= 0x06DC) return true;
    if (cp >= 0x06DF and cp <= 0x06E4) return true;
    if (cp >= 0x06E7 and cp <= 0x06E8) return true;
    if (cp >= 0x06EA and cp <= 0x06ED) return true;
    if (cp >= 0x06F0 and cp <= 0x06F9) return true; // Extended Arabic-Indic digits
    if (cp >= 0x0711 and cp == 0x0711) return true; // Syriac
    if (cp >= 0x0730 and cp <= 0x074A) return true;
    if (cp >= 0x07A6 and cp <= 0x07B0) return true; // Thaana
    if (cp >= 0x07C0 and cp <= 0x07C9) return true; // NKo digits
    if (cp >= 0x07EB and cp <= 0x07F3) return true;
    if (cp >= 0x0901 and cp <= 0x0903) return true; // Devanagari combining
    if (cp == 0x093C) return true;
    if (cp >= 0x093E and cp <= 0x094D) return true;
    if (cp >= 0x0951 and cp <= 0x0954) return true;
    if (cp >= 0x0962 and cp <= 0x0963) return true;
    if (cp >= 0x0966 and cp <= 0x096F) return true; // Devanagari digits
    // Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam combining + digits
    if (cp >= 0x0981 and cp <= 0x0983) return true;
    if (cp >= 0x09BC and cp <= 0x09CD) return true;
    if (cp >= 0x09E2 and cp <= 0x09E3) return true;
    if (cp >= 0x09E6 and cp <= 0x09EF) return true; // Bengali digits
    if (cp >= 0x0A01 and cp <= 0x0A03) return true;
    if (cp >= 0x0A3C and cp <= 0x0A4D) return true;
    if (cp >= 0x0A66 and cp <= 0x0A6F) return true; // Gurmukhi digits
    if (cp >= 0x0AE6 and cp <= 0x0AEF) return true; // Gujarati digits
    if (cp >= 0x0B66 and cp <= 0x0B6F) return true; // Oriya digits
    if (cp >= 0x0BE6 and cp <= 0x0BEF) return true; // Tamil digits
    if (cp >= 0x0C66 and cp <= 0x0C6F) return true; // Telugu digits
    if (cp >= 0x0CE6 and cp <= 0x0CEF) return true; // Kannada digits
    if (cp >= 0x0D66 and cp <= 0x0D6F) return true; // Malayalam digits
    // Thai combining + digits
    if (cp >= 0x0E31 and cp == 0x0E31) return true;
    if (cp >= 0x0E34 and cp <= 0x0E3A) return true;
    if (cp >= 0x0E47 and cp <= 0x0E4E) return true;
    if (cp >= 0x0E50 and cp <= 0x0E59) return true; // Thai digits
    // Lao
    if (cp >= 0x0EB1 and cp == 0x0EB1) return true;
    if (cp >= 0x0EB4 and cp <= 0x0EB9) return true;
    if (cp >= 0x0EBB and cp <= 0x0EBC) return true;
    if (cp >= 0x0EC8 and cp <= 0x0ECD) return true;
    if (cp >= 0x0ED0 and cp <= 0x0ED9) return true; // Lao digits
    // Tibetan
    if (cp >= 0x0F18 and cp <= 0x0F19) return true;
    if (cp >= 0x0F20 and cp <= 0x0F29) return true; // Tibetan digits
    if (cp == 0x0F35 or cp == 0x0F37 or cp == 0x0F39) return true;
    if (cp >= 0x0F3E and cp <= 0x0F3F) return true;
    if (cp >= 0x0F71 and cp <= 0x0F84) return true;
    if (cp >= 0x0F86 and cp <= 0x0F87) return true;
    if (cp >= 0x0F90 and cp <= 0x0F97) return true;
    if (cp >= 0x0F99 and cp <= 0x0FBC) return true;
    if (cp == 0x0FC6) return true;
    // Myanmar
    if (cp >= 0x1040 and cp <= 0x1049) return true; // Myanmar digits
    if (cp >= 0x1050 and cp <= 0x109D) return true; // Myanmar combining

    // Hangul Jamo (combining, Mn)
    if (cp >= 0x1160 and cp <= 0x11FF) return true;

    // Other_ID_Continue (ECMAScript 특별 예외)
    if (cp == 0x00B7) return true; // MIDDLE DOT
    if (cp == 0x0387) return true; // GREEK ANO TELEIA
    if (cp >= 0x1369 and cp <= 0x1371) return true; // Ethiopic digits

    // Connector punctuation (Pc)
    if (cp == 0x203F or cp == 0x2040) return true; // UNDERTIE, CHARACTER TIE
    if (cp == 0xFE33 or cp == 0xFE34) return true; // PRESENTATION FORM
    if (cp == 0xFE4D or cp == 0xFE4E or cp == 0xFE4F) return true;
    if (cp == 0xFF3F) return true; // FULLWIDTH LOW LINE

    // Fullwidth digits
    if (cp >= 0xFF10 and cp <= 0xFF19) return true;

    return false;
}

// ============================================================
// Tests
// ============================================================

test "decodeUtf8: ASCII" {
    const result = decodeUtf8("A");
    try std.testing.expectEqual(@as(u21, 'A'), result.codepoint);
    try std.testing.expectEqual(@as(u3, 1), result.len);
}

test "decodeUtf8: 2-byte UTF-8" {
    // é = U+00E9 = 0xC3 0xA9
    const result = decodeUtf8("\xC3\xA9");
    try std.testing.expectEqual(@as(u21, 0x00E9), result.codepoint);
    try std.testing.expectEqual(@as(u3, 2), result.len);
}

test "decodeUtf8: 3-byte UTF-8 (한)" {
    // 한 = U+D55C = 0xED 0x95 0x9C
    const result = decodeUtf8("\xED\x95\x9C");
    try std.testing.expectEqual(@as(u21, 0xD55C), result.codepoint);
    try std.testing.expectEqual(@as(u3, 3), result.len);
}

test "decodeUtf8: 4-byte UTF-8 (emoji)" {
    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80
    const result = decodeUtf8("\xF0\x9F\x98\x80");
    try std.testing.expectEqual(@as(u21, 0x1F600), result.codepoint);
    try std.testing.expectEqual(@as(u3, 4), result.len);
}

test "isIdentifierStart: ASCII" {
    try std.testing.expect(isIdentifierStart('a'));
    try std.testing.expect(isIdentifierStart('Z'));
    try std.testing.expect(isIdentifierStart('_'));
    try std.testing.expect(isIdentifierStart('$'));
    try std.testing.expect(!isIdentifierStart('0'));
    try std.testing.expect(!isIdentifierStart('+'));
}

test "isIdentifierStart: Unicode" {
    try std.testing.expect(isIdentifierStart(0x00E9)); // é (Latin)
    try std.testing.expect(isIdentifierStart(0x4E2D)); // 中 (CJK)
    try std.testing.expect(isIdentifierStart(0xD55C)); // 한 (Hangul)
    try std.testing.expect(isIdentifierStart(0x03B1)); // α (Greek)
    try std.testing.expect(isIdentifierStart(0x0410)); // А (Cyrillic)
}

test "isIdentifierContinue: digits and special" {
    try std.testing.expect(isIdentifierContinue('0'));
    try std.testing.expect(isIdentifierContinue('9'));
    try std.testing.expect(isIdentifierContinue('a'));
    try std.testing.expect(isIdentifierContinue('$'));
    try std.testing.expect(isIdentifierContinue(0x200C)); // ZWNJ
    try std.testing.expect(isIdentifierContinue(0x200D)); // ZWJ
    try std.testing.expect(!isIdentifierContinue('+'));
    try std.testing.expect(!isIdentifierContinue(' '));
}
