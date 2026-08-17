import 'package:http/http.dart' as http;
import 'logger_service.dart';

class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  factory LinkPreviewData.fromJson(Map<String, dynamic> json) {
    return LinkPreviewData(
      url: json['url'] ?? '',
      title: json['title'],
      description: json['description'],
      imageUrl: json['image'],
      siteName: json['site_name'],
    );
  }
}

class LinkPreviewService {
  static final LinkPreviewService _instance = LinkPreviewService._internal();
  factory LinkPreviewService() => _instance;
  LinkPreviewService._internal();

  final Map<String, LinkPreviewData> _cache = {};

  // Extract URLs from text
  static List<String> extractUrls(String text) {
    final urlRegex = RegExp(
      r'(https?:\/\/(?:www\.|(?!www))[a-zA-Z0-9][a-zA-Z0-9-]+[a-zA-Z0-9]\.[^\s]{2,}|www\.[a-zA-Z0-9][a-zA-Z0-9-]+[a-zA-Z0-9]\.[^\s]{2,}|https?:\/\/(?:www\.|(?!www))[a-zA-Z0-9]+\.[^\s]{2,}|www\.[a-zA-Z0-9]+\.[^\s]{2,})',
      caseSensitive: false,
    );
    
    return urlRegex.allMatches(text).map((match) => match.group(0)!).toList();
  }

  // Check if text contains URL
  static bool containsUrl(String text) {
    return extractUrls(text).isNotEmpty;
  }

  // Get link preview with caching
  Future<LinkPreviewData?> getLinkPreview(String url) async {
    // Check cache first
    if (_cache.containsKey(url)) {
      return _cache[url];
    }

    try {
      // Normalize URL
      String normalizedUrl = url;
      if (!url.startsWith('http')) {
        normalizedUrl = 'https://$url';
      }

      // Try to fetch using linkpreview API or fallback to manual parsing
      final preview = await _fetchWithLinkPreviewAPI(normalizedUrl) ??
                      await _fetchWithManualParsing(normalizedUrl);
      
      if (preview != null) {
        _cache[url] = preview;
      }
      
      return preview;
    } catch (e) {
      LoggerService.error('Error fetching link preview', error: e, tag: 'LinkPreview');
      return null;
    }
  }

  // Method 1: Using linkpreview API (requires API key)
  Future<LinkPreviewData?> _fetchWithLinkPreviewAPI(String url) async {
    try {
      // Using a free alternative API or implement your own backend
      // For now, we'll use a simple approach with metadata parsing
      return null; // Skip API method for now, use manual parsing
    } catch (e) {
      return null;
    }
  }

  // Method 2: Manual HTML parsing (fallback)
  Future<LinkPreviewData?> _fetchWithManualParsing(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final html = response.body;
        return _parseHtmlMeta(html, url);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // Parse HTML meta tags
  LinkPreviewData? _parseHtmlMeta(String html, String url) {
    try {
      String? title;
      String? description;
      String? imageUrl;
      String? siteName;

      // Parse title
      final titleMatch = RegExp(r'<title>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
      if (titleMatch != null) {
        title = titleMatch.group(1)?.trim();
      }

      // Parse Open Graph tags (simplified)
      try {
        final ogTitleMatch = RegExp(r'og:title').firstMatch(html);
        final ogDescMatch = RegExp(r'og:description').firstMatch(html);
        final ogImageMatch = RegExp(r'og:image').firstMatch(html);
        
        if (ogTitleMatch != null && title == null) {
          title = _extractDomain(url);
        }
        if (ogDescMatch != null) {
          description = 'Preview available';
        }
        if (ogImageMatch != null) {
          imageUrl = null;
        }
      } catch (e) {
        // Ignore regex errors
      }

      // Only return if we have at least a title
      if (title != null || description != null) {
        return LinkPreviewData(
          url: url,
          title: title ?? _extractDomain(url),
          description: description,
          imageUrl: imageUrl,
          siteName: siteName,
        );
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  // Extract domain from URL for fallback
  String _extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (e) {
      return url;
    }
  }

  // Clear cache
  void clearCache() {
    _cache.clear();
  }

  // Get cached preview without network call
  LinkPreviewData? getCachedPreview(String url) {
    return _cache[url];
  }
}
