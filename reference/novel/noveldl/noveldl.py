import os
import requests
from bs4 import BeautifulSoup
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import codecs

# セッション共通化
session = requests.Session()
session.headers.update({'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                                      '(KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36'})

# ------------------------------
# カクヨム用関数
# ------------------------------
def loadfromhtml(url: str) -> str:
    res = session.get(url)
    return res.text

def elimbodytags(base: str) -> str:
    return re.sub('<.*?>', '', base).replace(' ', '')

def changebrks(base: str) -> str:
    return re.sub('<br />', '\r\n', base)

def tagfilter(line: str) -> str:
    tmp = changebrks(line)
    tmp = elimbodytags(tmp)
    return tmp

def get_novel_title(body: str) -> str:
    title_match = re.search(r'<title>(.*?) - カクヨム</title>', body)
    if title_match:
        title = title_match.group(1).strip()
        title = re.sub(r'[\\/:*?"<>|]', '', title)
        return title
    return "無題"

def parsetoppage(body: str, base_url: str):
    page_list = []
    ep_pattern = r'"__typename":"Episode","id":".*?","title":".*?",'
    ep_matches = re.findall(ep_pattern, body)

    for ep in ep_matches:
        purl_id_match = re.search(r'"id":"(.*?)"', ep)
        if purl_id_match:
            purl_id = purl_id_match.group(1)
            purl_full_url = f"{base_url}/episodes/{purl_id}"
            page_list.append(purl_full_url)
    return page_list

def parsepage_to_file(url, index, novel_name):
    page_content = loadfromhtml(url)
    sect_match = re.search(r'<p class="widget-episodeTitle.*?">.*?</p>', page_content)
    if sect_match:
        sect_title = re.sub('<.*?>', '', sect_match.group(0)).strip()
        text_matches = re.findall(r'<p id="p.*?</p>', page_content)
        text_content = "\r\n".join(tagfilter(m) for m in text_matches)
        if text_content:
            folder_index = (index - 1) // 999 + 1
            subfolder_name = f"{folder_index:03}"
            subfolder_path = os.path.join(novel_name, subfolder_name)
            os.makedirs(subfolder_path, exist_ok=True)
            file_name = f"{index:03}.txt"
            file_path = os.path.join(subfolder_path, file_name)
            if os.path.exists(file_path):
                print(f"{file_path} は既に存在します。スキップします。")
                return
            with codecs.open(file_path, "w", "utf-8") as fout:
                fout.write(f"【タイトル】{sect_title}\r\n\r\n{text_content}")
            print(f"{file_path} に保存しました。")

def download_kakuyomu(url, start_index=1):
    toppage_content = loadfromhtml(url)
    novel_name = get_novel_title(toppage_content)
    os.makedirs(novel_name, exist_ok=True)
    page_list = parsetoppage(toppage_content, url)
    print(f"{len(page_list)} 話の目次を取得しました。")

    # 並列処理
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(parsepage_to_file, page_list[i], i+1, novel_name): i for i in range(start_index-1, len(page_list))}
        for future in as_completed(futures):
            time.sleep(0.05)  # サーバー負荷軽減

# ------------------------------
# 小説家になろう用関数
# ------------------------------
def fetch_url(url, cookies=None):
    try:
        res = session.get(url, cookies=cookies)
        res.raise_for_status()
        return res
    except requests.RequestException as e:
        print(f"Error fetching {url}: {e}")
        return None

def fetch_novel_info(url, cookies=None):
    full_url = url
    sublist = []
    while True:
        res = fetch_url(full_url, cookies)
        if not res: break
        soup = BeautifulSoup(res.text, 'lxml')
        title_text = soup.find('title').get_text().strip()
        sublist += soup.select('.p-eplist__sublist .p-eplist__subtitle')
        next_page = soup.select_one('.c-pager__item--next')
        if next_page and next_page.get('href'):
            full_url = f"https://{full_url.split('/')[2]}{next_page['href']}"
        else:
            break
    return title_text, sublist

def download_sublist(sublist, title_text, start_chapter=1, cookies=None):
    title_text = re.sub(r'[<>:"/\\|?*]', '', title_text)
    base_folder = f'./{title_text}'
    os.makedirs(base_folder, exist_ok=True)
    def download_task(i, sub):
        sub_title = sub.text.strip()
        link = sub.get('href')
        if not link: return
        folder_num = (i // 999) + 1
        folder_name = f"{folder_num:03}"
        folder_path = os.path.join(base_folder, folder_name)
        os.makedirs(folder_path, exist_ok=True)
        file_name = f"{i+1:03d}.txt"
        file_path = os.path.join(folder_path, file_name)
        if os.path.exists(file_path): return
        res = fetch_url(f'https://{url_input.split("/")[2]}{link}', cookies)
        if not res: return
        soup = BeautifulSoup(res.text, 'lxml')
        sub_body_text = soup.select_one('.p-novel__body')
        if not sub_body_text: return
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(f"{sub_title}\n\n{sub_body_text.text.strip()}")
        print(f"{file_name} downloaded in folder {folder_name} ({i+1}/{len(sublist)})")
        time.sleep(0.05)

    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = [executor.submit(download_task, i, sub) for i, sub in enumerate(sublist[start_chapter-1:])]
        for f in as_completed(futures):
            pass
    print("Download completed!")

# ------------------------------
# メイン関数
# ------------------------------
def main():
    global url_input
    url_input = input("URLを入力してください: ").strip()
    if "kakuyomu.jp" in url_input:
        start_index = int(input("何話目から開始しますか？ (1 〜 ): ").strip())
        download_kakuyomu(url_input, start_index)
    elif "ncode.syosetu.com" in url_input:
        start_chapter = int(input("何話目から開始しますか？ (1 〜 ): ").strip())
        title_text, sublist = fetch_novel_info(url_input)
        download_sublist(sublist, title_text, start_chapter)
    elif "novel18.syosetu.com" in url_input:
        start_index = int(input("何話目から開始しますか？ (1 〜 ): ").strip())
        title_text, sublist = fetch_novel_info(url_input, cookies={'over18': 'yes'})
        download_sublist(sublist, title_text, start_index, cookies={'over18': 'yes'})
    else:
        print("無効なURLです。")

if __name__ == '__main__':
    main()
