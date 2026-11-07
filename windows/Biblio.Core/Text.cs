using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Biblio.Core;

/// <summary>Metin yardımcıları (Swift: Engine.fold, squash, norm ...).</summary>
public static class Text_
{
    private static readonly (string, string)[] Specials =
        { ("’", "'"), ("‘", "'"), ("ı", "i"), ("İ", "I"), ("ß", "ss"), ("ø", "o"), ("Ø", "O"), ("ł", "l"), ("Ł", "L"), ("đ", "d"), ("æ", "ae"), ("œ", "oe") };
    private const string Allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -'";

    /// <summary>ASCII'ye indirger. Satır sonları boşluğa, ligatürler harflere çevrilir.</summary>
    public static string Fold(string s)
    {
        var t = s.Normalize(NormalizationForm.FormKC);
        var sb = new StringBuilder(t.Length);
        foreach (var c in t) sb.Append(char.IsWhiteSpace(c) ? ' ' : c);
        t = sb.ToString();
        foreach (var (a, b) in Specials) t = t.Replace(a, b);
        var d = t.Normalize(NormalizationForm.FormD);
        sb.Clear();
        foreach (var c in d)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark && Allowed.Contains(c)) sb.Append(c);
        return string.Join(" ", sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    public static string Squash(string s)
    {
        var sb = new StringBuilder();
        foreach (var c in Fold(s).ToLowerInvariant()) if (char.IsLetterOrDigit(c)) sb.Append(c);
        return sb.ToString();
    }

    public static string Norm(string s)
    {
        var f = Fold(s).ToLowerInvariant();
        var parts = new List<string>();
        var cur = new StringBuilder();
        foreach (var c in f)
        {
            if (char.IsLetterOrDigit(c)) cur.Append(c);
            else if (cur.Length > 0) { parts.Add(cur.ToString()); cur.Clear(); }
        }
        if (cur.Length > 0) parts.Add(cur.ToString());
        return string.Join(" ", parts);
    }

    public static HashSet<string> Tokens(string s) =>
        Norm(s).Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length > 3).ToHashSet();

    public static IEnumerable<string> Matches(string pattern, string s, int group = 0)
    {
        foreach (Match m in Regex.Matches(s, pattern))
            if (m.Groups[group].Success) yield return m.Groups[group].Value;
    }

    public static string[]? Groups(string pattern, string s)
    {
        var m = Regex.Match(s, pattern);
        if (!m.Success) return null;
        return Enumerable.Range(1, m.Groups.Count - 1).Select(i => m.Groups[i].Success ? m.Groups[i].Value : "").ToArray();
    }

    public static string Capitalized(string s)
    {
        var sb = new StringBuilder();
        bool start = true;
        foreach (var c in s)
        {
            if (char.IsLetter(c)) { sb.Append(start ? char.ToUpperInvariant(c) : char.ToLowerInvariant(c)); start = false; }
            else { sb.Append(c); start = !char.IsDigit(c) && c != '\''; }
        }
        return sb.ToString();
    }

    public static string[] Lines(string s) => s.Split('\n');
    public static string Trim(string s, string chars) => s.Trim(chars.ToCharArray());
    public static bool IsAllUpper(string s) => s == s.ToUpperInvariant();
    public static bool HasLower(string s) => s.Any(char.IsLower);
}
