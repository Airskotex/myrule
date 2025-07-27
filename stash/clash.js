/**
 * 规则地址
 https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Clash/
 */
// 常量定义
const CONSTANTS = {
    CONNECTIVITY_TEST_URL: "http://www.google.com/generate_204",
    DEFAULT_INTERVAL: 86400,
    DEFAULT_TEST_INTERVAL: 300,
    DEFAULT_TOLERANCE: 50
};

// 正则表达式预编译，'|' = 或
const REGEX = {
    exclude: new RegExp("^(?!.*(下载|测试)$).*$", "u"),
    home: /(原生|Native|Premium|专线|砖线|家宽).*x([4-9]|[1-9]\d+)/i,
    daily: /(原生|Native|Premium|专线|砖线|家宽)(?!.*x([4-9]|[1-9]\d+))/i,
    down: /WHM|大流量|下载|down|claw/i,
    spotify: /oracle/i,
    video: /AWS|Ali|流媒体|Netflix|Disney/i
};

// 规则提供者的默认配置
const DEFAULT_RULE_PROVIDER_CONFIG = {
    type: "http",
    format: "yaml",
    interval: CONSTANTS.DEFAULT_INTERVAL,
    behavior: "classical"
};

// 国内DNS服务器 [[11]]
const domesticNameservers = [
  "https://223.5.5.5/dns-query", // 阿里DoH
  "https://doh.pub/dns-query" // 腾讯DoH
];

// 国外DNS服务器 [[11]]
const foreignNameservers = [
  "https://cloudflare-dns.com/dns-query", // CloudflareDNS
  "https://77.88.8.8/dns-query", //YandexDNS
  "https://8.8.4.4/dns-query#ecs=1.1.1.1/24&ecs-override=true", // GoogleDNS
  "https://208.67.222.222/dns-query#ecs=1.1.1.1/24&ecs-override=true", // OpenDNS
  "https://9.9.9.9/dns-query", //Quad9DNS
];

// DNS配置 - 防DNS泄漏配置 [[11]]
const dnsConfig = {
  "enable": true,
  "listen": "0.0.0.0:1053",
  "ipv6": true,
  "prefer-h3": false,
  "respect-rules": true,
  "use-system-hosts": false,
  "cache-algorithm": "arc",
  "enhanced-mode": "fake-ip",
  "fake-ip-range": "198.18.0.1/16",
  "fake-ip-filter": [
    // 本地主机/设备
    "+.lan",
    "+.local",
    // Windows网络出现小地球图标
    "+.msftconnecttest.com",
    "+.msftncsi.com",
    // QQ快速登录检测失败
    "localhost.ptlogin2.qq.com",
    "localhost.sec.qq.com",
    // 微信快速登录检测失败
    "localhost.work.weixin.qq.com"
  ],
  "default-nameserver": ["223.5.5.5","1.2.4.8"],
  "nameserver": [...foreignNameservers],
  "proxy-server-nameserver":[...domesticNameservers],
  "direct-nameserver":[...domesticNameservers],
  "direct-nameserver-follow-policy":false,
  "nameserver-policy": {
    "geosite:cn": domesticNameservers
  }
};

// AI服务列表
const AI_SERVICES = ["OpenAi", "Claude", "Gemini"];
// 视频服务列表
const VIDEO_SERVICES = ["YouTube"];
// 下载服务列表
const DOWNLOAD_SERVICES = ["Telegram","GoogleDrive"];
// Spotify服务列表
const SPOTIFY_SERVICES = ["Spotify"];

const ruleProviders = {
    "Ipv6": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/Ipv6.txt",
        path: "./ruleset/tnnevol/Ipv6.yaml"
    },
    "LocalAreaNetwork": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/LocalAreaNetwork.txt",
        path: "./ruleset/tnnevol/LocalAreaNetwork.yaml"
    },
    "BanAD": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/BanAD.txt",
        path: "./ruleset/tnnevol/BanAD.yaml"
    },
    "BanProgramAD": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/BanProgramAD.txt",
        path: "./ruleset/tnnevol/BanProgramAD.yaml"
    },
    "GoogleFCM": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/GoogleFCM.txt",
        path: "./ruleset/tnnevol/GoogleFCM.yaml"
    },
    "Bing": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/Bing.txt",
        path: "./ruleset/tnnevol/Bing.yaml"
    },
    "OneDrive": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/OneDrive.txt",
        path: "./ruleset/tnnevol/OneDrive.yaml"
    },
    "Microsoft": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/Microsoft.txt",
        path: "./ruleset/tnnevol/Microsoft.yaml"
    },
    "Apple": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/Apple.txt",
        path: "./ruleset/tnnevol/Apple.yaml"
    },
    "Telegram": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Telegram/Telegram.yaml",
        path: "./ruleset/tnnevol/Telegram.yaml"
    },
    "GoogleDrive": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/GoogleDrive/GoogleDrive.yaml",
        path: "./ruleset/tnnevol/GoogleDrive.yaml"
    },
    "Claude": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Claude/Claude.yaml",
        path: "./ruleset/tnnevol/Claude.yaml"
    },
    "Gemini": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Gemini/Gemini.yaml",
        path: "./ruleset/tnnevol/Gemini.yaml"
    },
    "OpenAi": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/OpenAi.txt",
        path: "./ruleset/tnnevol/OpenAi.yaml"
    },
    "Spotify": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Spotify/Spotify.yaml",
        path: "./ruleset/tnnevol/Spotify.yaml"
    },
    "YouTube": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/YouTube.txt",
        path: "./ruleset/tnnevol/YouTube.yaml"
    },
    "ProxyGFWlist": {
        ...DEFAULT_RULE_PROVIDER_CONFIG,
        url: "https://raw.githubusercontent.com/tnnevol/ACL4SSR/refs/heads/master/ClashVerge/dist/clash-rules/acl4ssr-online-full/ProxyGFWlist.txt",
        path: "./ruleset/tnnevol/ProxyGFWlist.yaml"
    }
};

// 获取符合正则表达式的代理组
function getProxiesByRegex(proxies, regex, concatProxies = []) {
    return [
        ...proxies
            .filter((e) => regex.test(e.name) && REGEX.exclude.test(e.name))
            .map((e) => e.name),
        ...concatProxies,
    ];
}

// 配置验证
function validateConfig(config) {
    if (!config.proxies || !Array.isArray(config.proxies)) {
        throw new Error('Invalid proxies configuration');
    }
    return true;
}

function main(config) {
    try {
        // 验证配置
        validateConfig(config);
        
        // 处理原始代理，确保开启UDP [[11]]
        const originalProxies = config.proxies || [];
        const processedProxies = originalProxies.map(proxy => {
            if (proxy && typeof proxy === 'object' && proxy.name) {
                // 为所有代理节点开启UDP
                proxy.udp = true;
                return proxy;
            } else {
                console.warn("警告：发现一个无效或缺少名称的原始代理配置:", proxy);
                return null;
            }
        }).filter(p => p !== null);
        
        // 更新代理列表
        config.proxies = processedProxies;
        
        const allProxies = config.proxies.map((e) => e.name);
        const homeProxies = ((filtered) => filtered.length > 0 ? filtered : allProxies)(allProxies.filter(proxy => REGEX.home.test(proxy)));
        const dailyProxies = ((filtered) => filtered.length > 0 ? filtered : allProxies)(allProxies.filter(proxy => REGEX.daily.test(proxy)));
        const downProxies = ((filtered) => filtered.length > 0 ? filtered : allProxies)(allProxies.filter(proxy => REGEX.down.test(proxy)));
        const spotifyProxies = ((filtered) => filtered.length > 0 ? filtered : allProxies)(allProxies.filter(proxy => REGEX.spotify.test(proxy)));
        const videoProxies = ((filtered) => filtered.length > 0 ? filtered : allProxies)(allProxies.filter(proxy => REGEX.video.test(proxy)));
        
        // 设置代理组
        config["proxy-groups"] = [
            {
                name: "所有节点",
                type: "url-test",
                proxies: allProxies,
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            },
            {
                name: "高倍纯净节点",
                type: "url-test",
                proxies: homeProxies,
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            },
            {
                name: "日常纯净节点",
                type: "url-test",
                proxies: dailyProxies,
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            },
            {
                name: "日常节点",
                type: "fallback",
                //proxies: dailyProxies.length > 0 ? dailyProxies : allProxies,
                proxies: ["日常纯净节点", "所有节点"],
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            },
            {
                name: "视频节点",
                type: "url-test",
                proxies: videoProxies,
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            },
            {
                name: "下载节点",
                type: "url-test",
                proxies: downProxies,
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            },
            {
                name: "Spotify",
                type: "url-test",
                proxies: spotifyProxies,
                url: CONSTANTS.CONNECTIVITY_TEST_URL,
                interval: CONSTANTS.DEFAULT_TEST_INTERVAL,
                tolerance: CONSTANTS.DEFAULT_TOLERANCE
            }
        ];

        // 添加DNS配置 - 防DNS泄漏 [[3]]
        config["dns"] = dnsConfig;

        // 设置规则提供者
        config["rule-providers"] = ruleProviders;

        // 设置规则
        config["rules"] = [
            // AI服务规则
            ...AI_SERVICES.map(service => `RULE-SET,${service},高倍纯净节点`),

            // AI相关域名规则
            "DOMAIN-SUFFIX,gemini.google.com,高倍纯净节点",
            "DOMAIN-SUFFIX,perplexity.ai,高倍纯净节点",
            "DOMAIN-SUFFIX,signaler-pa.clients6.google.com,高倍纯净节点",
            "DOMAIN-SUFFIX,genspark.ai,高倍纯净节点",
            "DOMAIN-SUFFIX,you.com,高倍纯净节点",
            "DOMAIN-SUFFIX,x.ai,高倍纯净节点",
            "DOMAIN-SUFFIX,grok.com,高倍纯净节点",
            "DOMAIN-SUFFIX,dify.ai,高倍纯净节点",
            "DOMAIN-SUFFIX,hancat.work,高倍纯净节点",
            "DOMAIN-SUFFIX,cloudns.net,高倍纯净节点",
            "DOMAIN-SUFFIX,ping0.cc,高倍纯净节点",
            "DOMAIN-SUFFIX,ipdata.co,高倍纯净节点",
            "DOMAIN-SUFFIX,digitalplat.org,高倍纯净节点",
            "DOMAIN-SUFFIX,mail.google.com,高倍纯净节点",
            "DOMAIN-SUFFIX,dataonline.vn,高倍纯净节点",
            "DOMAIN-SUFFIX,nodeseek.com,高倍纯净节点",
            "DOMAIN-SUFFIX,ipinfo.io,高倍纯净节点",

            // 视频服务规则
            ...VIDEO_SERVICES.map(service => `RULE-SET,${service},视频节点`),
            "DOMAIN-SUFFIX,manus.im,视频节点",
            "DOMAIN-SUFFIX,jsdelivr.net,视频节点",

            // 下载服务规则
            ...DOWNLOAD_SERVICES.map(service => `RULE-SET,${service},下载节点`),
            "DOMAIN-SUFFIX,dl.delivery.mp.microsoft.com,下载节点",
            "PROCESS-NAME,IDMan.exe,下载节点",
            "PROCESS-NAME,GoodSync.exe,下载节点",

            //Spotify服务规则
            ...SPOTIFY_SERVICES.map(service => `RULE-SET,${service},Spotify`),

            // 代理规则
            "RULE-SET,Bing,日常节点",
            "RULE-SET,ProxyGFWlist,日常节点",
            "DOMAIN-SUFFIX,browserleaks.com,日常节点",
            "DOMAIN-SUFFIX,claw.cloud,日常节点",
            "DOMAIN-SUFFIX,sub.contaction.me,日常节点",
            "DOMAIN-SUFFIX,cursor.com,日常节点",
            "DOMAIN-SUFFIX,thunderbird.net,日常节点",
            "DOMAIN-SUFFIX,please-recruit.me,日常节点",
            "DOMAIN-SUFFIX,serv00.com,日常节点",
            "DOMAIN-SUFFIX,sublink.proxys.ip-ddns.com,日常节点",
            "DOMAIN-SUFFIX,app.warp.dev,日常节点",
            "DOMAIN-SUFFIX,tencentcloud.com,视频节点",

            // 直连规则
            "GEOIP,CN,DIRECT",
            "DOMAIN-SUFFIX,sub-page.proxys.ip-ddns.com,DIRECT",
            "DOMAIN-SUFFIX,canva.cn,DIRECT",
            "DOMAIN-SUFFIX,warhut.cn,DIRECT",
            "DOMAIN-SUFFIX,linux.do,DIRECT",
            "DOMAIN-SUFFIX,aicnn.cn,DIRECT",
            "DOMAIN-SUFFIX,login.bce.baidu.com,DIRECT",
            "DOMAIN-SUFFIX,boju.cc,DIRECT",
            "DOMAIN-SUFFIX,riskbird.com,DIRECT",
            "DOMAIN-SUFFIX,rewards.bing.com,DIRECT",
            "DOMAIN-SUFFIX,cpuid.com,DIRECT",
            "DOMAIN-SUFFIX,deepl.com,DIRECT",
            "DOMAIN-SUFFIX,netcup.com,DIRECT",
            "DOMAIN-SUFFIX,customercontrolpanel.de,DIRECT",
            "DOMAIN-SUFFIX,love.52pokemon.cc,DIRECT",
            "RULE-SET,Apple,DIRECT",

            // IP-CIDR规则
            "IP-CIDR,10.0.0.0/24,DIRECT",
            "IP-CIDR,172.168.10.0/24,DIRECT",
            "IP-CIDR,117.175.156.232/24,DIRECT",

            // 默认规则
            "MATCH,日常节点"
        ];

        return config;
    } catch (error) {
        console.error('配置处理出错:', error);
        return config; // 返回原始配置
    }
}
