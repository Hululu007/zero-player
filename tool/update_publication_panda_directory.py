"""Build the app's reviewed directory from a saved Panda homepage and probe JSON."""

import argparse
import base64
import csv
from html.parser import HTMLParser
from datetime import date
import json
from pathlib import Path
import re
from urllib.parse import quote, unquote, urlsplit, urlunsplit


ASSET = Path("assets/catalogs/books/panda-directory.json")
DOMAIN = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}")
AUXILIARY = {"tools", "gallery", "learning", "translate"}
NON_BOOK_HOSTS = {
    "convert.xmsoushu.com", "qread.xmsoushu.com", "learn.xmsoushu.com",
    "ixuexila.com", "imoyukik.com", "ikaning.com", "www.hpcbristol.net",
    "ihpm.cn", "www.idongde.com", "koodo.960960.xyz", "ja.ukiyo-e.org",
    "useum.org", "www.mvyxws.com", "www.onegreen.net", "www.tianditu.gov.cn",
    "dictionary-share.herokuapp.com", "www.ageeye.cn", "cuobiezi.net",
    "familysearch.org", "freemdict.com", "www.lgbowu.com", "kindlefere.com",
}

REPURPOSED_HOSTS = {
    "www.anysafer.com", "www.51dupdf.com", "www.ziliaoh.com", "www.yanjiyou.com",
    "book.idoubi.net",
    "swpdf.com", "www.tingchina.com",
    "www.x5v.net",
    "www.dzsfx.com",
    "zure.fun", "www.worldofmagazine.com", "new-qk.lifves.com",
    "www.2345daohang.com",
}

NATIVE = {
    "kgbook.com": "kgbook-public-catalogue",
    "www.dushupai.com": "dushupai-public-catalogue",
    "www.gutenberg.org": "project-gutenberg-mirror",
    "new.shuge.org": "shuge-open",
    "shuge.org": "shuge-open",
    "book.tstrs.me": "tstrs-catalogue",
    "sobooks.cc": "sobooks-public-catalogue",
    "sobooks.net": "sobooks-public-catalogue",
    "tadoku.org": "tadoku-free",
    "gallica.bnf.fr": "bnf-gallica-public-catalogue",
    "digital.library.upenn.edu": "upenn-online-books",
    "openstax.org": "openstax-textbooks",
    "www.aozora.gr.jp": "aozora-bunko",
    "www.planetebook.com": "planet-ebook-classics",
    "hong.ioc.u-tokyo.ac.jp": "tokyo-hong-catalogue",
    "www.bookstack.cn": "panda-bookstack",
    "taiwanebook.ncl.edu.tw": "panda-taiwan-ebook",
    "salttiger.com": "panda-salttiger",
    "ibooks.org.cn": "panda-ibooks",
    "zulu-ebooks.com": "panda-zulu-ebooks",
    "www.shukui.net": "panda-shukui",
    "moreread.me": "panda-moreread",
    "www.cbeta.org": "panda-cbeta",
    "ctext.org": "panda-ctext",
    "www.cp.com.cn": "panda-commercial-press",
    "www.ilixiangguo.com": "panda-imaginist",
    "http561856124.wordpress.com": "panda-kanhaoshu",
    "www.taoshudang.com": "panda-taoshudang",
    "www.huiyankan.com": "panda-huiyankan",
    "klib.me": "panda-klib-ranking",
    "daizhige.org": "panda-daizhige",
    "www.daizhige.org": "panda-daizhige",
    "www.readinglife.com": "panda-thinkingdom",
    "www.dookbook.com": "panda-dookbook",
    "haodoo.net": "haodoo-public-catalogue",
    "www.haodoo.net": "haodoo-public-catalogue",
    "book.sciencereading.cn": "panda-science-reading",
    "ebooklist.mobi": "panda-ebooklist",
    "booklink.me": "panda-booklink",
    "d-pdf.com": "panda-dpdf",
    "www.shiren.org": "panda-shiren",
    "www.cdstm.cn": "panda-cdstm",
    "www.vorleser.net": "panda-vorleser",
    "hanchi.ihp.sinica.edu.tw": "panda-hanji",
    "www.pingshu365.com": "panda-pingshu365",
    "361tsg.cn": "panda-361-library",
    "shidianguji.com": "panda-shidian",
    "www.hinabook.com": "panda-hinabook",
    "www.qqszz.net": "panda-qianqiu",
    "www.35ppt.com": "panda-qianqiu",
    "www.shuzhou.cc": "panda-shuzhou",
    "xue.bookln.cn": "panda-bookln",
    "www.oalib.com": "panda-oalib",
    "ocw.mit.edu": "panda-mit-ocw",
    "www.modernhistory.org.cn": "panda-modernhistory",
    "book.tinynews.org": "panda-tinynews",
    "www.jb51.net": "panda-jb51",
    "www.cnpereading.com": "panda-cnpereading",
    "cadal.edu.cn": "panda-cadal",
    "www.huxiangwenku.cn": "panda-huxiangwenku",
    "freemagazines.top": "panda-freemagazines",
    "www.aisixiang.com": "panda-aisixiang",
    "ebook.hep.com.cn": "panda-hep",
    "www.gujiguan.com": "panda-gujiguan",
    "ykt.eduyun.cn": "panda-smartedu",
    "www.zglibrary.com": "panda-zglibrary",
    "kindle.smgzd.com": "panda-kindle-comics",
}

NOTES = {
    "book.tinynews.org": "全站搜索后核验数字编号的图书详情。可打开《国家神道与日本人》，《斯通纳》详情仍跳回首页。原站获取页的检索结果未经验证为实际电子书。",
    "www.jb51.net": "索引公开目录列出的 57 个分类、205 页书目，跨分类搜索。作者匹配以目录明确署名为准。原站详情公布的网盘分享可识别，网页交互下载保留原站入口。",
    "www.99csw.com": "公开书目可核对。当前环境的桌面、移动端及 read 子站遇到站方验证或连接失败。此次桌面和 read 子站图书目录均返回 403。",
    "www.marxists.org": "公开网页可核对中文目录和 PDF 文库。应用所在环境直连主站及复查的官方镜像均未获得可验证响应。",
    "www.cnpereading.com": "使用站方公开全站图书检索。支持书名、作者和 ISBN，阅览与订阅权限由原站管理。",
    "cadal.edu.cn": "使用站方公开馆藏检索，按题名及作者查找古籍、民国图书和当代图书等。可直接打开馆藏书目，阅览与借阅由原站管理。",
    "www.huxiangwenku.cn": "使用公开书目与全站图书检索，按书名或作者精确筛选并打开原站详情。",
    "freemagazines.top": "公开杂志全站标题检索、封面和逐期详情。可识别详情中发布的 EasyUpload PDF 预览，预览和下载由外部站点处理。",
    "www.aisixiang.com": "接入全站学术文章搜索，按标题和作者分别检索并核验文章题名与署名，原站可阅览。",
    "wx.zhlhh.com": "浙江图书馆连环画入口可打开。匿名搜索对站方推荐词、书名及作者均返回零条，保留馆方入口。",
    "zure.fun": "当前首页显示域名在售。",
    "www.worldofmagazine.com": "旧地址跳转至经营矿石礼品的 WonderDig 商店。",
    "new-qk.lifves.com": "现行页面是初见通用 API 文档，未找到原有杂志或网盘查询服务。",
    "ebook.hep.com.cn": "旧路径失效时，使用同站现行入口与公开全站检索。按书名或署名复筛。详情与阅览由高教书苑提供。",
    "www.gujiguan.com": "旧 index.aspx 返回 404，现行同域古籍资源知识平台支持公开字段检索。应用显示实际版本和责任者，原站选择版本及登录阅览。",
    "ykt.eduyun.cn": "教育部确认旧平台升级为国家中小学智慧教育平台。接入官方公开四分卷教材索引，原站详情请求在本机返回 403。",
    "freemagazinepdf.com": "旧地址跳转到第三方域名，未证实为 Freemagazines 同站迁移。",
    "www.zglibrary.com": "使用公开全部书目 272 页，按题名和书目署名离线检索，保留逐书详情和封面。借阅由原站处理。",
    "kindle.smgzd.com": "使用漫画区 Kindle 版入口的 163 页公开总目录，跨漫画分类按标题查找，保留站方帖子地址。样本帖子需要浏览器验证。",
    "ihparchive.ihp.sinica.edu.tw": "导航中的古典目录链接返回站方 CGI 状态错误，公开入口另返回浏览器跳转页。",
    "www.2345daohang.com": "现有首页显示域名出售提示。",
    "www.ruiwen.com": "12 个公开目录可读取到四科教材书目。样本逐页阅读依赖原站图床，跨科目检查的图片返回 404，保留目录入口。",
    "obook.cc": "公开书单首页可访问。复查站方 Halo 公开搜索接口超时，保留原站入口。",
    "www.dzsfx.com": "前一次页面显示体育直播；本轮首页和查询均返回 403，未查到原电子书服务。",
    "ibooks.org.cn": "使用书籍作者分类识别书目，支持作者检索。",
    "www.anysafer.com": "导航标为 PDF 电子书，实测站点已是养花知识网站。",
    "www.51dupdf.com": "导航标为 PDF 论坛，实测站点已是聚合外链的网络小说网页。",
    "www.ziliaoh.com": "导航标为图书网，实测首页是影视聚合页。",
    "www.yanjiyou.com": "导航标为言又几书店，实测首页是影视聚合页。",
    "www.shukui.net": "主库和从库均可检索，原站详情保留站方提供的获取方式。",
    "moreread.me": "公开书目检索，样本详情跳转至登录页。",
    "www.bookstack.cn": "公开书籍搜索、封面及书目页。目录未提供可用的作者字段。",
    "taiwanebook.ncl.edu.tw": "公开馆藏全库检索与书目详情，阅览资格由原站控制。",
    "salttiger.com": "公开技术书目及站方公布的百度网盘入口。",
    "zulu-ebooks.com": "公开检索和作者元数据，逐书核对站方公布的 PDF、EPUB 和 MOBI 入口。",
    "haodoo.net": "好读二代官网确认与好读旧站的关系。映射到现有 haodoo.org 适配器，免费 EPUB 由原站结账页提供。",
    "digital.library.upenn.edu": "已核对宾大现行在线书目域名 onlinebooks.library.upenn.edu。",
    "www.aozora.gr.jp": "已接入官方 CSV 书目，按书名和作者离线查询，跳转原站阅读。",
    "www.planetebook.com": "已验证作者目录与原站 EPUB、PDF、MOBI 入口。",
    "ctext.org": "公开书目数据可离线检索。官方链接解析可定位原书，原站正文可能要求人机验证。",
    "www.cbeta.org": "中華電子佛典的公开书目可离线检索。CBETA Online 提供阅览。",
    "www.cp.com.cn": "公开出版目录，实测可按书名检索并打开官方详情。",
    "www.ilixiangguo.com": "公开出版目录与作者，站内搜索结果筛出具体图书。",
    "http561856124.wordpress.com": "查询公开书单，从图书文件标题提取书目和站方公布的城通分享。",
    "sobooks.net": "旧入口页面明确指向 sobooks.cc，复用已有 SoBooks 适配器。",
    "www.taoshudang.com": "原站恢复可访问。全站检索支持书名、作者及详情页。",
    "www.huiyankan.com": "原站恢复可访问。公开推荐书目提供题名和详情链接。",
    "klib.me": "完整公开总榜生成 116 条离线书目。详情使用实测的 HTTPS 地址。",
    "www.daizhige.org": "使用站方 Git 仓库公开古籍书目，离线查询各藏的书名，多卷书进入原站总览。",
    "www.readinglife.com": "官方四类精选书目提供书名与封面。按作者检索查询站方作家目录和对应作家代表作。",
    "www.dookbook.com": "官方精选书目含题名、封面及站方发布的豆瓣/当当详情。按作者查站方作家目录及代表作。",
    "book.idoubi.net": "实测当前已改作影视站，未找到导航所指图书分享服务。",
    "www.duku.cn": "官网介绍读库 App 仅对会员开放，公开网页指向其店铺。",
    "www.jiumodiary.com": "首页提示需要通过站方公众号取得验证码，或由用户完成微信验证。",
    "sou-yun.cn": "可查诗词，古籍检索进入站方链接的第三方登录验证。",
    "swpdf.com": "原网址显示域名在售。",
    "www.tingchina.com": "实测已改作体育赛事直播网站。",
    "book.sciencereading.cn": "公开全库检索返回书名、作者、ISBN 和官方详情，阅读权限由原站处理。",
    "ebooklist.mobi": "电子书搜索和详情可访问。逐书读取站方公开发布的夸克及百度网盘入口。",
    "www.shiren.org": "六个古典、现代、国际诗库目录可离线检索。支持原站阅读及同站公布的 PDF。",
    "www.x5v.net": "Bookle 旧地址显示域名出售提示，未提供图书目录。",
    "www.cdstm.cn": "科普阅读荟的四个官方图书系列可离线检索，包含书名、作者、ISBN 与原站公布的 PDF。",
    "www.vorleser.net": "公开德语有声书全库检索，按书名、作者过滤，识别逐书公布的 PDF 文本。音频在原站。",
    "hanchi.ihp.sinica.edu.tw": "2013 至 2026 年公开年度书目可按书名和作者离线检索，逐书打开原站阅读器。",
    "www.pingshu365.com": "沿用全站名称搜索，按书名或站方作者署名过滤。逐书页由原站提供音频。",
    "361tsg.cn": "旧域名发布页明确指向 361tsg.top。现行站支持全站搜索，网盘领取及站方权限要求在原站处理。",
    "shidianguji.com": "解析站方公开搜索网页中的推荐书目与全文命中来源，按题名或作者过滤。原站提供完整书库。",
    "www.hinabook.com": "官方商店当前公开 7 个具体图书商品，支持离线书名匹配。商品页未公布可提取的作者字段。",
    "www.qqszz.net": "旧域名跳转至同名千秋书在现行站 www.35ppt.com。公开全站书目和原站游客页发布的网盘入口。",
    "www.shuzhou.cc": "站方公开搜索接口返回书名和发布的网盘分享。支持书名及明确署名匹配。",
    "xue.bookln.cn": "公开配套资源书目接口支持书名、作者、封面和出版者。配套文件由原站提供。",
    "www.oalib.com": "全站聚合检索需要站方验证。应用接入公开的自有期刊检索，并核对期刊出版方公布的 PDF。",
    "ocw.mit.edu": "用 MIT Learn 公开检索查课程名称和讲师。课程公开下载页可检出讲义、作业及考试 PDF。",
    "www.modernhistory.org.cn": "用站方公开检索查文献题名及责任者，按文献类型打开原站详情。原站下载要求登录。",
    "booklink.me": "公开小说索引分别提供书名、作者检索及章节详情。",
    "d-pdf.com": "公开英文书目支持书名、作者检索并返回原站 PDF 下载页面。",
}

STATUS_LABELS = {
    "native": "应用内书源",
    "website": "原站入口",
    "limited": "站点验证或限制",
    "changedDomain": "跳转至其他域或降级",
    "changedPurpose": "站点用途已变更",
    "unavailable": "未验证可用入口",
    "invalid": "地址无效",
    "auxiliary": "辅助资源",
    "archived": "导航回收站",
}

class DirectoryParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.groups = []
        self.section = None
        self.link = None
        self.text = None

    def handle_starttag(self, tag, raw):
        attrs = dict(raw)
        if tag == "section" and attrs.get("id"):
            self.section = {"id": attrs["id"], "name": "", "links": []}
            self.groups.append(self.section)
        if self.section is None:
            return
        if tag == "h2" and not self.section["name"]:
            self.text = ("h2", self.section)
        if tag == "a" and attrs.get("href"):
            self.link = {"href": attrs["href"], "name": ""}
        if tag == "h3" and self.link is not None:
            self.text = ("h3", self.link)

    def handle_data(self, content):
        if self.text is not None:
            self.text[1]["name"] += content

    def handle_endtag(self, tag):
        if self.text is not None and tag == self.text[0]:
            self.text = None
        if tag == "a" and self.link is not None:
            if self.link["name"].strip():
                self.section["links"].append(self.link)
            self.link = None
        if tag == "section":
            self.section = None


def unwrap(href):
    prefix = "/goUrl?url="
    if href.startswith(prefix):
        # unquote preserves literal plus characters in the Base64 payload.
        raw = unquote(href[len(prefix):].split("&", 1)[0])
        try:
            href = base64.b64decode(raw + "=" * (-len(raw) % 4), validate=True).decode()
        except (ValueError, UnicodeError):
            return ""
    return href.strip()


def review(group, link, probes, direct):
    url = unwrap(link["href"])
    row = {"name": " ".join(link["name"].split()), "original": url}
    try:
        target = urlsplit(url)
        host = target.hostname or ""
        valid = (
            target.scheme in {"http", "https"}
            and DOMAIN.fullmatch(host)
            and target.port in {None, 80 if target.scheme == "http" else 443}
            and target.username is None
            and target.password is None
            and len(url) <= 2048
            and not any(ord(char) < 32 for char in unquote(url))
        )
    except ValueError:
        valid = False
        host = ""
    address = ""
    if valid:
        address = urlunsplit((
            "https", host, quote(target.path or "/", safe="/%:@!$&'()*+,;=-_.~"),
            quote(target.query, safe="%:@!$&'()*+,;=/?-_.~"), "",
        ))
    homepage = probes.get(host, {}) if valid and target.path in {"", "/"} and not target.query else {}
    probe = direct.get(address, homepage)
    if probe:
        row["probe"] = probe
    if host in NOTES:
        row["note"] = NOTES[host]
    redirect = probe.get("redirectHost")
    status = probe.get("status")
    if group in AUXILIARY or host in NON_BOOK_HOSTS:
        row["status"] = "auxiliary"
    elif group == "broken":
        row["status"] = "archived"
    elif not valid:
        row["status"] = "invalid"
    elif host in NATIVE:
        row.update(status="native", source=NATIVE[host])
    elif host in REPURPOSED_HOSTS:
        row["status"] = "changedPurpose"
    elif probe.get("verification") or status in {401, 403, 429, 451}:
        row["status"] = "limited"
    elif redirect and (
        host.removeprefix("www.") != redirect.removeprefix("www.")
        or probe.get("redirectScheme") != "https"
    ):
        row["status"] = "changedDomain"
    elif (status in {200, 206} and probe.get("mime") == "text/html") or (
        redirect and status in {301, 302, 307, 308}
    ):
        row["status"] = "website"
        row["website"] = urlunsplit(("https", host, target.path or "/", target.query, target.fragment))
    else:
        row["status"] = "unavailable"
    return row


def spreadsheet_cell(value):
    return "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("homepage", type=Path)
    parser.add_argument("probes", type=Path)
    parser.add_argument("--direct", type=Path)
    parser.add_argument("--audit", type=Path)
    parser.add_argument("--date", type=date.fromisoformat, required=True)
    args = parser.parse_args()

    homepage = DirectoryParser()
    homepage.feed(args.homepage.read_text(encoding="utf-8"))
    probes = json.loads(args.probes.read_bytes())
    direct = json.loads(args.direct.read_bytes()) if args.direct else {}
    groups = [
        {
            "id": group["id"],
            "name": group["name"].strip(),
            "entries": [review(group["id"], link, probes, direct) for link in group["links"]],
        }
        for group in homepage.groups
        if group["links"]
    ]
    count = sum(len(group["entries"]) for group in groups)
    if len(groups) < 10 or count < 300:
        raise ValueError("The Panda homepage appears to be incomplete")
    data = {"version": 1, "reviewed": args.date.isoformat(), "groups": groups}
    ASSET.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.audit:
        with args.audit.open("w", encoding="utf-8-sig", newline="") as audit:
            writer = csv.writer(audit, delimiter="\t")
            writer.writerow(("分类", "站名", "原链接", "接入状态", "应用书源", "原站入口", "HTTPS 探测", "备注"))
            for group in groups:
                for row in group["entries"]:
                    values = (
                        group["name"], row["name"], row["original"], STATUS_LABELS[row["status"]],
                        row.get("source", ""), row.get("website", ""),
                        json.dumps(row["probe"], ensure_ascii=False) if "probe" in row else "",
                        row.get("note", ""),
                    )
                    writer.writerow(map(spreadsheet_cell, values))
    print(f"Wrote {count} entries in {len(groups)} groups to {ASSET}")


if __name__ == "__main__":
    main()
