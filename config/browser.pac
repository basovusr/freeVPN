// ============================================================
//  浏览器定向代理 PAC 文件
//
//  作用: 只让「需要的域名」走本地代理，其余全部直连。
//  好处: 完全不修改系统代理设置 (ProxyEnable 保持 0)，
//        微信/钉钉/游戏/国内网站完全不受影响 —— 零副作用。
//
//  本地代理: 127.0.0.1:7890
// ============================================================

var PROXY_HOST = "127.0.0.1";
var PROXY_PORT = 7890;
var PROXY = "PROXY " + PROXY_HOST + ":" + PROXY_PORT;

// ---- 走代理的域名 ---- 
var PROXY_DOMAINS = [
  // 搜索 / 百科 / 资料
  "google.com", "google.com.hk", "googleapis.com", "gstatic.com",
  "googleusercontent.com", "googlesource.com", "googlevideo.com",
  "youtube.com", "ytimg.com", "ggpht.com", "withgoogle.com",
  "wikipedia.org", "wikimedia.org", "wiktionary.org",
  "bing.com", "duckduckgo.com", "archive.org", "openlibrary.org",

  // X / 社交
  "x.com", "twitter.com", "t.co", "twimg.com",
  "reddit.com", "redd.it", "quora.com", "medium.com",
  "telegram.org", "t.me", "discord.com", "discord.gg",
  "facebook.com", "instagram.com", "linkedin.com",

  // 开发 / 学习
  "github.com", "githubusercontent.com", "githubassets.com", "github.io",
  "gitlab.com", "bitbucket.org", "sourceforge.net",
  "stackoverflow.com", "stackexchange.com", "serverfault.com",
  "superuser.com", "askubuntu.com", "stackapps.com",
  "npmjs.com", "npmjs.org", "pypi.org", "python.org", "pythonhosted.org",
  "docker.com", "docker.io", "hub.docker.com", "ghcr.io",
  "rust-lang.org", "crates.io", "golang.org", "go.dev",
  "nodejs.org", "deno.land", "bun.sh", "rubygems.org",
  "jetbrains.com", "vscode.dev", "visualstudio.com", "code.visualstudio.com",
  "readthedocs.io", "readthedocs.org", "mdn.mozilla.org",
  "developer.mozilla.org", "mozilla.org", "packagist.org",
  "maven.org", "apache.org", "gradle.org", "kotlinlang.org",
  "llvm.org", "gnu.org", "kernel.org", "debian.org", "ubuntu.com",
  "archlinux.org", "centos.org", "redhat.com", "fedoraproject.org",

  // 学术 / 论文
  "arxiv.org", "nature.com", "science.org", "sciencedirect.com",
  "springer.com", "ieee.org", "acm.org", "jstor.org",
  "researchgate.net", "semanticscholar.org", "pubmed.ncbi.nlm.nih.gov",
  "ncbi.nlm.nih.gov", "nih.gov", "cell.com", "wiley.com",
  "tandfonline.com", "sagepub.com", "oup.com", "cambridge.org",
  "scholar.google.com", "books.google.com", "translate.google.com",
  "huggingface.co", "kaggle.com", "colab.research.google.com",
  "overleaf.com", "zotero.org", "mendeley.com", "endnote.com",

  // AI 服务
  "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
  "anthropic.com", "claude.ai", "gemini.google.com", "bard.google.com",
  "perplexity.ai", "poe.com", "midjourney.com", "stability.ai",
  "cohere.ai", "groq.com", "openrouter.ai", "deepmind.com",
  "mistral.ai", "together.ai", "replicate.com", "fal.ai",
  "cursor.com", "cursor.sh", "codeium.com", "tabnine.com",

  // 云 / 基础设施
  "cloudflare.com", "workers.dev", "pages.dev", "cloudflare-dns.com",
  "vercel.com", "netlify.com", "netlify.app", "render.com",
  "heroku.com", "railway.app", "fly.io", "supabase.com",
  "digitalocean.com", "linode.com", "vultr.com", "hetzner.com",
  "amazonaws.com", "aws.amazon.com", "azure.com", "oracle.com",
  "gist.github.com", "gitpod.io", "codesandbox.io", "stackblitz.com",

  // 资讯 / 其他
  "dropbox.com", "slack.com", "notion.so", "figma.com",
  "spotify.com", "imgur.com", "v2ex.com", "ycombinator.com",
  "news.ycombinator.com", "pinterest.com", "tumblr.com",
  "bbc.com", "bbc.co.uk", "cnn.com", "nytimes.com", "reuters.com",
  "theguardian.com", "bloomberg.com", "wsj.com", "economist.com",
  "ft.com", "washingtonpost.com", "apnews.com", "npr.org"
];

// ---- 强制直连（优先级最高，防止误伤） ----
var DIRECT_DOMAINS = [
  "localhost", "127.0.0.1",
  "baidu.com", "qq.com", "taobao.com", "tmall.com", "jd.com",
  "alipay.com", "aliyun.com", "alicdn.com", "weibo.com",
  "bilibili.com", "zhihu.com", "csdn.net", "163.com", "126.com",
  "sohu.com", "sina.com.cn", "sina.com", "toutiao.com",
  "douyin.com", "xiaohongshu.com", "meituan.com", "dianping.com",
  "gitee.com", "cnblogs.com", "oschina.net", "jianshu.com",
  "tencent.com", "huawei.com", "xiaomi.com", "bytedance.com",
  "gov.cn", "edu.cn", "ac.cn", "miit.gov.cn", "12306.cn",
  "qcloud.com", "myqcloud.com", "jdcloud.com", "hicloud.com"
];

function hostMatches(host, suffix) {
  if (host === suffix) return true;
  // 后缀匹配必须带点，避免 notgoogle.com 被误判为 google.com
  return host.length > suffix.length + 1 &&
         host.substring(host.length - suffix.length - 1) === "." + suffix;
}

function FindProxyForURL(url, host) {
  host = host.toLowerCase();

  // 1. 内网 / 本机直连
  if (isPlainHostName(host) ||
      shExpMatch(host, "10.*") ||
      shExpMatch(host, "192.168.*") ||
      shExpMatch(host, "172.1[6-9].*") ||
      shExpMatch(host, "172.2[0-9].*") ||
      shExpMatch(host, "172.3[01].*") ||
      shExpMatch(host, "127.*") ||
      shExpMatch(host, "169.254.*")) {
    return "DIRECT";
  }

  // 2. 直连白名单优先
  for (var i = 0; i < DIRECT_DOMAINS.length; i++) {
    if (hostMatches(host, DIRECT_DOMAINS[i])) return "DIRECT";
  }

  // 3. 代理名单
  for (var j = 0; j < PROXY_DOMAINS.length; j++) {
    if (hostMatches(host, PROXY_DOMAINS[j])) return PROXY;
  }

  // 4. 默认直连（最保守，绝不影响国内日常使用）
  return "DIRECT";
}
