using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    public sealed class Source
    {
        public long id { get; set; }
        public double? rating { get; set; }
        public string version { get; set; }
        public string taper { get; set; }
        public string gear { get; set; }
        public string generation { get; set; }
        public string length { get; set; }
        public string status { get; set; }
        public string lineage { get; set; }
        public string recordingType { get; set; }
        public string codec { get; set; }
        public string lossless { get; set; }
        internal string SearchText;
    }

    public sealed class SetlistItem
    {
        public string title { get; set; }
        public string info { get; set; }
        public string encore { get; set; }
    }

    public sealed class Show
    {
        public long id { get; set; }
        public string date { get; set; }
        public string venue { get; set; }
        public string city { get; set; }
        public string state { get; set; }
        public string country { get; set; }
        public string status { get; set; }
        public string festival { get; set; }
        public string tour { get; set; }
        public List<Source> sources { get; set; }
        public List<SetlistItem> setlist { get; set; }
        public int setlistOmitted { get; set; }
        public List<string> songs { get; set; }
        internal string SearchText;
    }

    public sealed class FilterOptions
    {
        public string Search { get; set; }
        public double MinimumRating { get; set; }
        public string RatingMode { get; set; }
        public string FromYear { get; set; }
        public string ToYear { get; set; }
        public string RecordingType { get; set; }
        public bool SavedOnly { get; set; }
        public string Sort { get; set; }
        public FilterOptions()
        {
            Search = ""; RatingMode = "any"; FromYear = ""; ToYear = "";
            RecordingType = "all"; Sort = "rating";
        }
    }

    public sealed class ShowMatch
    {
        public Show Show { get; set; }
        public List<Source> Sources { get; set; }
        public Source BestSource { get; set; }
        public double? Rating { get; set; }
    }

    public sealed class Catalog
    {
        public string snapshotDate { get; set; }
        public string source { get; set; }
        public string ratingDescription { get; set; }
        public Dictionary<string, string> songAlbums { get; set; }
        public List<Show> shows { get; set; }

        private const int MaximumJsonBytes = 32 * 1024 * 1024;
        private static readonly HashSet<string> ValidStatuses = new HashSet<string>(new string[] { "OTD", "Confirmed", "Unconfirmed", "Unknown" }, StringComparer.Ordinal);
        private static readonly Regex UrlPattern = new Regex(@"(?:(?:[a-z][a-z0-9+.-]*:)?//|www\.|mailto:|magnet:)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        public static Catalog Load()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Desktop.ToolDrive.catalog.json"))
            {
                if (stream == null) throw new InvalidOperationException("The embedded show catalog is missing.");
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                    return FromJson(reader.ReadToEnd());
            }
        }

        public static Catalog FromJson(string json)
        {
            bool pruned;
            return FromJson(json, out pruned);
        }

        internal static Catalog FromJson(string json, out bool pruned)
        {
            if (String.IsNullOrWhiteSpace(json) || json.Length > MaximumJsonBytes || Encoding.UTF8.GetByteCount(json) > MaximumJsonBytes)
                throw new InvalidDataException("The catalog is empty or exceeds the 32 MB metadata limit.");
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = MaximumJsonBytes, RecursionLimit = 32 };
                object raw = serializer.Deserialize<object>(json);
                if (!(raw is IDictionary<string, object>)) throw new InvalidDataException("The catalog must be a JSON object.");
                ValidateRaw(raw, 0);
                Catalog catalog = serializer.ConvertToType<Catalog>(raw);
                if (catalog == null || catalog.shows == null || catalog.shows.Count == 0 || catalog.shows.Count > 50000)
                    throw new InvalidDataException("The catalog must contain between 1 and 50,000 shows.");
                ValidateDate(catalog.snapshotDate, "snapshot date");
                ValidateText(catalog.source, 2048, true); ValidateText(catalog.ratingDescription, 4096, false);
                HashSet<long> showIds = new HashSet<long>(), sourceIds = new HashSet<long>();
                pruned = false;
                foreach (Show show in catalog.shows)
                {
                    if (show == null || show.id <= 0 || !showIds.Add(show.id)) throw new InvalidDataException("Show IDs must be positive and unique.");
                    ValidateDate(show.date, "show date"); ValidateStatus(show.status);
                    ValidateText(show.venue, 2048, true); ValidateText(show.city, 512, false); ValidateText(show.state, 512, false);
                    ValidateText(show.country, 512, false); ValidateText(show.festival, 2048, false); ValidateText(show.tour, 2048, false);
                    if (show.sources == null || show.sources.Count > 4096) throw new InvalidDataException("Each show must contain a bounded recording-source list.");
                    foreach (Source item in show.sources)
                    {
                        if (item == null || item.id <= 0 || !sourceIds.Add(item.id) || sourceIds.Count > 250000)
                            throw new InvalidDataException("Recording-source IDs must be positive and unique throughout the catalog.");
                        ValidateStatus(item.status);
                        if (item.rating.HasValue && (Double.IsNaN(item.rating.Value) || Double.IsInfinity(item.rating.Value) || item.rating.Value < 0 || item.rating.Value > 10))
                            throw new InvalidDataException("Sound ratings must be finite numbers between 0 and 10, or null.");
                        if (item.rating == 0) item.rating = null;
                        ValidateText(item.version, 128, false); ValidateText(item.taper, 2048, false); ValidateText(item.gear, 8192, false);
                        ValidateText(item.generation, 512, false); ValidateText(item.length, 128, false); ValidateText(item.lineage, 32768, false);
                        ValidateText(item.recordingType, 128, true); ValidateText(item.codec, 128, false); ValidateText(item.lossless, 128, false);
                    }
                    if (show.setlist == null) show.setlist = new List<SetlistItem>();
                    if (show.songs == null) show.songs = new List<string>();
                    if (show.setlist.Count > 2048 || show.songs.Count > 2048 || show.setlistOmitted < 0 || show.setlistOmitted > 10000)
                        throw new InvalidDataException("A show contains an invalid song list.");
                    foreach (SetlistItem item in show.setlist)
                    {
                        if (item == null) throw new InvalidDataException("Setlist items cannot be null.");
                        ValidateText(item.title, 2048, true); ValidateText(item.info, 8192, false); ValidateText(item.encore, 128, false);
                    }
                    foreach (string title in show.songs) ValidateText(title, 2048, true);
                    if (show.sources.RemoveAll(recording => recording.status != "OTD") > 0) pruned = true;
                    if (show.sources.Count > 0 && show.status != "OTD")
                    {
                        show.status = "OTD";
                        pruned = true;
                    }
                }
                if (catalog.shows.RemoveAll(show => show.sources.Count == 0) > 0) pruned = true;
                if (catalog.shows.Count == 0) throw new InvalidDataException("The catalog has no shows with an on-drive recording.");
                foreach (Show show in catalog.shows) catalog.Prepare(show);
                return catalog;
            }
            catch (InvalidDataException) { throw; }
            catch (Exception error)
            {
                if (error is ArgumentException || error is InvalidOperationException || error is FormatException || error is OverflowException)
                    throw new InvalidDataException("The catalog metadata could not be read safely.", error);
                throw;
            }
        }

        private static void ValidateRaw(object value, int depth)
        {
            if (depth > 32) throw new InvalidDataException("The catalog nesting limit was exceeded.");
            string text = value as string;
            if (text != null) { ValidateText(text, 32768, false); return; }
            IDictionary<string, object> map = value as IDictionary<string, object>;
            if (map != null)
            {
                if (map.Count > 128) throw new InvalidDataException("A metadata object contains too many fields.");
                foreach (KeyValuePair<string, object> item in map)
                {
                    ValidateText(item.Key, 128, true);
                    if (item.Key == "id")
                    {
                        decimal id;
                        if (!IsNumber(item.Value) || !Decimal.TryParse(Convert.ToString(item.Value, CultureInfo.InvariantCulture), NumberStyles.Number, CultureInfo.InvariantCulture, out id) || id <= 0 || id > Int64.MaxValue || Decimal.Truncate(id) != id)
                            throw new InvalidDataException("Catalog IDs must be positive whole numbers.");
                    }
                    if (item.Key == "rating" && item.Value != null && !IsNumber(item.Value)) throw new InvalidDataException("Sound ratings must be numeric or null.");
                    ValidateRaw(item.Value, depth + 1);
                }
                return;
            }
            System.Collections.IList list = value as System.Collections.IList;
            if (list != null)
            {
                if (list.Count > 250000) throw new InvalidDataException("A metadata list is too large.");
                foreach (object item in list) ValidateRaw(item, depth + 1);
            }
        }
        private static bool IsNumber(object value)
        {
            return value is Int32 || value is Int64 || value is Decimal || value is Double || value is Single || value is Int16 || value is Byte;
        }
        private static void ValidateText(string value, int maximumLength, bool required)
        {
            if ((required && String.IsNullOrWhiteSpace(value)) || (value != null && (value.Length > maximumLength || UrlPattern.IsMatch(value))))
                throw new InvalidDataException("Catalog text is missing, too long, or contains a URL.");
        }
        private static void ValidateDate(string value, string name)
        {
            DateTime parsed;
            if (value == null || value.Length != 10 || !DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed))
                throw new InvalidDataException("The catalog contains an invalid " + name + ".");
        }
        private static void ValidateStatus(string value)
        {
            if (value == null || !ValidStatuses.Contains(value)) throw new InvalidDataException("The catalog contains an unknown recording status.");
        }

        private void Prepare(Show show)
        {
            if (show.songs == null) show.songs = new List<string>();
            if (show.setlist == null) show.setlist = new List<SetlistItem>();
            show.SearchText = TextUtil.Normalize(String.Join(" ", new string[] {
                show.date, (show.date ?? "").Replace('-', '/'), show.venue, show.city, show.state, show.country,
                show.festival, show.tour, String.Join(" ", show.songs), String.Join(" ", show.setlist.Select(x => x.title)) }));
            foreach (Source item in show.sources)
                item.SearchText = TextUtil.Normalize(String.Join(" ", new string[] { item.taper, item.gear, item.lineage, item.version, item.recordingType }));
        }

        public static double? SoundRating(Source source)
        {
            if (source == null || !source.rating.HasValue || Double.IsNaN(source.rating.Value) || Double.IsInfinity(source.rating.Value)) return null;
            return source.rating.Value > 0 && source.rating.Value <= 10 ? source.rating : null;
        }

        public bool SourceMatches(Show show, Source item, FilterOptions options)
        {
            string[] tokens = TextUtil.Normalize(options.Search).Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            return SourceMatches(show, item, options, tokens);
        }

        private bool SourceMatches(Show show, Source item, FilterOptions options, string[] tokens)
        {
            double? rating = SoundRating(item);
            if (!String.IsNullOrEmpty(options.RecordingType) && options.RecordingType != "all" && item.recordingType != options.RecordingType) return false;
            if (options.RatingMode == "rated" && !rating.HasValue) return false;
            if (options.RatingMode == "unrated" && rating.HasValue) return false;
            if (options.MinimumRating > 0 && (!rating.HasValue || rating.Value < options.MinimumRating)) return false;
            string text = (show.SearchText ?? "") + " " + (item.SearchText ?? "");
            return tokens.All(token => text.IndexOf(token, StringComparison.Ordinal) >= 0);
        }

        public List<ShowMatch> Filter(FilterOptions options, ISet<string> saved)
        {
            if (options == null) options = new FilterOptions();
            List<ShowMatch> result = new List<ShowMatch>();
            if (!String.IsNullOrEmpty(options.FromYear) && !String.IsNullOrEmpty(options.ToYear) && String.CompareOrdinal(options.FromYear, options.ToYear) > 0) return result;
            string[] tokens = TextUtil.Normalize(options.Search).Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (Show show in shows)
            {
                if (show.SearchText == null) Prepare(show);
                string year = (show.date ?? "").Length >= 4 ? show.date.Substring(0, 4) : "";
                if (!String.IsNullOrEmpty(options.FromYear) && String.CompareOrdinal(year, options.FromYear) < 0) continue;
                if (!String.IsNullOrEmpty(options.ToYear) && String.CompareOrdinal(year, options.ToYear) > 0) continue;
                if (options.SavedOnly && (saved == null || !saved.Contains(show.id.ToString(CultureInfo.InvariantCulture)))) continue;
                List<Source> matching = show.sources.Where(item => SourceMatches(show, item, options, tokens)).ToList();
                if (matching.Count == 0) continue;
                Source best = matching.OrderByDescending(item => SoundRating(item) ?? -1).First();
                result.Add(new ShowMatch { Show = show, Sources = matching, BestSource = best, Rating = SoundRating(best) });
            }
            if (options.Sort == "newest") result = result.OrderByDescending(x => x.Show.date, StringComparer.Ordinal).ThenBy(x => x.Show.id).ToList();
            else if (options.Sort == "oldest") result = result.OrderBy(x => x.Show.date, StringComparer.Ordinal).ThenBy(x => x.Show.id).ToList();
            else if (options.Sort == "venue") result = result.OrderBy(x => x.Show.venue, StringComparer.CurrentCultureIgnoreCase).ThenByDescending(x => x.Show.date, StringComparer.Ordinal).ToList();
            else result = result.OrderByDescending(x => x.Rating ?? -1).ThenByDescending(x => x.Show.date, StringComparer.Ordinal).ThenBy(x => x.Show.id).ToList();
            return result;
        }
    }

    internal static class TextUtil
    {
        public static string Normalize(string value)
        {
            string text = (value ?? "").Replace("Æ", "AE").Replace("æ", "ae").Replace("Œ", "OE").Replace("œ", "oe").Normalize(NormalizationForm.FormD);
            StringBuilder output = new StringBuilder();
            foreach (char c in text) if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) output.Append(Char.ToLowerInvariant(c));
            return output.ToString().Normalize(NormalizationForm.FormC);
        }
        public static bool Useful(string value) { return !String.IsNullOrWhiteSpace(value) && value != "—" && value != "-" && !String.Equals(value, "unknown", StringComparison.OrdinalIgnoreCase); }
        public static string Display(string value) { return Useful(value) ? value : "Not documented"; }
        public static string Location(Show show) { return String.Join(", ", new string[] { show.city, show.state, show.country }.Where(Useful)); }
        public static string Score(Source source) { double? value = Catalog.SoundRating(source); return value.HasValue ? value.Value.ToString("0.0", CultureInfo.InvariantCulture) + " / 10" : "Unrated"; }
    }

    internal sealed class SavedStore
    {
        public HashSet<string> Ids = new HashSet<string>(StringComparer.Ordinal);
        public string Warning;
        private readonly string path;
        public SavedStore(IEnumerable<Show> shows)
        {
            path = Path.Combine(DesktopBootstrap.Profile, "saved-shows.json");
            try
            {
                if (File.Exists(path))
                {
                    List<string> values = new JavaScriptSerializer().Deserialize<List<string>>(File.ReadAllText(path, Encoding.UTF8));
                    if (values != null) foreach (string value in values)
                    {
                        long id;
                        if (Int64.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out id) && id > 0)
                            Ids.Add(id.ToString(CultureInfo.InvariantCulture));
                    }
                }
            }
            catch { Warning = "The saved list could not be loaded. You can save shows for this session."; }
        }
        public bool Contains(Show show) { return Ids.Contains(show.id.ToString(CultureInfo.InvariantCulture)); }
        public void Toggle(Show show)
        {
            string key = show.id.ToString(CultureInfo.InvariantCulture);
            if (!Ids.Remove(key)) Ids.Add(key);
            Persist();
        }
        internal void Persist()
        {
            string temp = null;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllText(temp, new JavaScriptSerializer().Serialize(Ids.OrderBy(x => x).ToArray()), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
                Warning = null;
            }
            catch { Warning = "Saved for this session. The saved list could not be written to your profile."; }
            finally { try { if (temp != null && File.Exists(temp)) File.Delete(temp); } catch { } }
        }
    }

}
