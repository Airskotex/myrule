// ==UserScript==
// @name         Linux.do&idcflare.com 抽奖检测与互动
// @namespace    http://tampermonkey.net/
// @version      0.9
// @description  检测 linux.do&idcflare.com 网站的"抽奖"标签帖子，对最近的未处理帖子进行点赞和随机评论，支持评论历史记录
// @author       Your Name
// @match        https://linux.do/*
// @match        https://idcflare.com/*
// @grant        GM_addStyle
// @grant        GM_setValue
// @grant        GM_getValue
// ==/UserScript==

(function() {
    'use strict';
/*
    const Config = {
        FETCH_URL: 'https://linux.do/tag/抽奖.json',
        BASE_URL: 'https://linux.do/t',
        POST_ACTION_URL: 'https://linux.do/post_actions.json',
        POSTS_URL: 'https://linux.do/posts',
        LIKE_ACTION_ID: 2,
        ONE_DAY_MS: 24 * 60 * 60 * 1000, // 一天前
        MAX_HISTORY_ITEMS: 5, // 最多保存5条历史记录
        HISTORY_KEY: 'lottery_comment_history' // 存储历史记录的键名
    };
*/
    // 获取当前域名
    const currentDomain = window.location.hostname;
    // 根据域名决定基础URL
    const baseUrl = currentDomain === 'idcflare.com'
        ? 'https://idcflare.com'
        : 'https://linux.do';
    const Config = {
        FETCH_URL: `${baseUrl}/tag/抽奖.json`,
        BASE_URL: `${baseUrl}/t`,
        POST_ACTION_URL: `${baseUrl}/post_actions.json`,
        POSTS_URL: `${baseUrl}/posts`,
        LIKE_ACTION_ID: 2,
        ONE_DAY_MS: 24 * 60 * 60 * 1000,
        MAX_HISTORY_ITEMS: 5,
        HISTORY_KEY: 'lottery_comment_history'
    };


    const StyleManager = {
        styles: `
            .lottery-popup {
                position: fixed; top: 57px; right: 90px; z-index: 10000;
                width: 180px; max-height: 80vh; overflow-y: auto;
                background: var(--popup-bg); padding: 20px;
                box-shadow: 0 8px 30px rgba(0,0,0,0.1);
                font-size: 14px; border-radius: 15px; cursor: move;
                transition: all 0.3s ease;
            }
            .lottery-popup.minimized {
                width: auto; height: auto; padding: 0;
                overflow: hidden; background: transparent;
                box-shadow: none;
            }
            .lottery-popup:hover { box-shadow: 0 12px 40px rgba(0,0,0,0.2); }
            .lottery-popup button {
                width: 100%; margin-top: 8px; padding: 10px;
                background: var(--button-bg); color: var(--button-color);
                border: none; border-radius: 6px; font-size: 14px; cursor: pointer;
                transition: all 0.3s ease;
            }
            .lottery-popup button:hover {
                background-color: var(--button-hover-bg);
                transform: translateY(-2px);
                box-shadow: 0 6px 15px rgba(0,0,0,0.1);
            }
            .minimizeButton {
                position: absolute; top: 0; left: 0; right: 0;
                height: 25px; background: transparent; border: none;
                color: var(--minimize-btn-color);
                display: flex; justify-content: center; align-items: center;
            }
            .lottery-popup.minimized .minimizeButton {
                position: static; height: auto; padding: 5px 10px;
                background: var(--button-bg); border-radius: 6px;
            }
            .minimizeButton:hover { color: var(--minimize-btn-hover-color); }
            .topic-link {
                display: block; margin-bottom: 5px;
                color: var(--link-color); text-decoration: none;
            }
            .topic-link:hover { text-decoration: underline; }
            #lotteryPopupContent { margin-top: 25px; }
            .lottery-popup.minimized #lotteryPopupContent { display: none; }
            .topic-link.failed { color: var(--failed-color); }
            .comment-used {
                font-size: 12px;
                color: #888;
                margin-left: 10px;
                font-style: italic;
            }
            .history-dialog {
                position: fixed;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                width: 300px;
                background: var(--popup-bg);
                padding: 20px;
                border-radius: 10px;
                box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                z-index: 10001;
            }
            .history-dialog h3 {
                margin-top: 0;
                margin-bottom: 15px;
                text-align: center;
            }
            .history-item {
                padding: 10px;
                margin-bottom: 5px;
                background: var(--item-bg);
                border-radius: 5px;
                cursor: pointer;
                transition: all 0.2s ease;
            }
            .history-item:hover {
                background: var(--item-hover-bg);
                transform: translateY(-2px);
            }
            .history-item:last-child {
                margin-bottom: 0;
            }
            .history-actions {
                display: flex;
                justify-content: space-between;
                margin-top: 15px;
            }
            .history-actions button {
                flex: 1;
                margin: 0 5px;
            }
            .history-overlay {
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(0,0,0,0.5);
                z-index: 10000;
            }
            @media (prefers-color-scheme: dark) {
                :root {
                    --popup-bg: #333; --button-bg: #444; --button-color: #f0f0f0;
                    --button-hover-bg: #555; --minimize-btn-color: #888;
                    --minimize-btn-hover-color: #fff; --link-color: #add8e6;
                    --failed-color: #888; --item-bg: #444; --item-hover-bg: #555;
                }
            }
            @media (prefers-color-scheme: light) {
                :root {
                    --popup-bg: #fff; --button-bg: #e0e0e0; --button-color: #333;
                    --button-hover-bg: #d5d5d5; --minimize-btn-color: #888;
                    --minimize-btn-hover-color: #333; --link-color: #0000ff;
                    --failed-color: #000; --item-bg: #f0f0f0; --item-hover-bg: #e0e0e0;
                }
            }
        `,
        injectStyles() {
            GM_addStyle(this.styles);
        }
    };

    const HistoryManager = {
        getHistory() {
            return GM_getValue(Config.HISTORY_KEY, []);
        },

        saveHistory(history) {
            GM_setValue(Config.HISTORY_KEY, history);
        },

        addToHistory(comment) {
            if (!comment || comment.trim() === '') return;

            let history = this.getHistory();

            // 如果已存在相同评论，先移除它
            history = history.filter(item => item !== comment);

            // 将新评论添加到数组开头
            history.unshift(comment);

            // 限制历史记录最大数量
            if (history.length > Config.MAX_HISTORY_ITEMS) {
                history = history.slice(0, Config.MAX_HISTORY_ITEMS);
            }

            this.saveHistory(history);
        }
    };

    const UIManager = {
        popup: null,
        content: null,
        minimizeButton: null,
        startButton: null,
        historyDialog: null,
        historyOverlay: null,

        initPopup() {
            this.popup = this.createElement('div', { class: 'lottery-popup minimized' });
            this.content = this.createElement('div', { id: 'lotteryPopupContent' });
            this.minimizeButton = this.createElement('button', { class: 'minimizeButton' }, '显示\n');
            this.startButton = this.createElement('button', {}, '开始处理');

            this.popup.append(this.minimizeButton, this.content, this.startButton);
            document.body.appendChild(this.popup);

            this.minimizeButton.addEventListener('click', () => this.togglePopupSize());
            this.startButton.addEventListener('click', () => this.showHistoryDialog());
            this.addDraggableFeature(this.popup);
        },

        createElement(tag, attributes, text) {
            const element = document.createElement(tag);
            Object.entries(attributes).forEach(([attr, value]) => element.setAttribute(attr, value));
            if (text) element.textContent = text;
            return element;
        },

        togglePopupSize() {
            this.popup.classList.toggle('minimized');
            this.minimizeButton.textContent = this.popup.classList.contains('minimized') ? '显示\n' : '隐藏';
        },

        updateContent(content) {
            this.content.innerHTML = content;
        },

        showHistoryDialog() {
            const history = HistoryManager.getHistory();

            // 创建遮罩层
            this.historyOverlay = this.createElement('div', { class: 'history-overlay' });

            // 创建对话框
            this.historyDialog = this.createElement('div', { class: 'history-dialog' });
            const title = this.createElement('h3', {}, '历史评论');

            // 创建内容区域
            const dialogContent = this.createElement('div', {});

            if (history.length === 0) {
                const emptyMessage = this.createElement('p', {}, '暂无历史记录，请输入新评论');
                dialogContent.appendChild(emptyMessage);
            } else {
                history.forEach(comment => {
                    const item = this.createElement('div', { class: 'history-item' }, comment);
                    item.addEventListener('click', () => {
                        this.closeHistoryDialog();
                        LotteryManager.start(comment);
                    });
                    dialogContent.appendChild(item);
                });
            }

            // 创建按钮区域
            const actionsArea = this.createElement('div', { class: 'history-actions' });

            const newCommentBtn = this.createElement('button', {}, '新评论');
            newCommentBtn.addEventListener('click', () => {
                this.closeHistoryDialog();
                LotteryManager.start();
            });

            const cancelBtn = this.createElement('button', {}, '取消');
            cancelBtn.addEventListener('click', () => this.closeHistoryDialog());

            actionsArea.append(newCommentBtn, cancelBtn);

            // 组装对话框
            this.historyDialog.append(title, dialogContent, actionsArea);

            // 添加到页面
            document.body.append(this.historyOverlay, this.historyDialog);
        },

        closeHistoryDialog() {
            if (this.historyDialog) {
                this.historyDialog.remove();
                this.historyDialog = null;
            }

            if (this.historyOverlay) {
                this.historyOverlay.remove();
                this.historyOverlay = null;
            }
        },

        addDraggableFeature(element) {
            let pos1 = 0, pos2 = 0, pos3 = 0, pos4 = 0;
            element.onmousedown = e => {
                if (e.target === this.minimizeButton) return;

                e.preventDefault();
                [pos3, pos4] = [e.clientX, e.clientY];
                document.onmouseup = () => document.onmouseup = document.onmousemove = null;
                document.onmousemove = e => {
                    e.preventDefault();
                    [pos1, pos2] = [pos3 - e.clientX, pos4 - e.clientY];
                    [pos3, pos4] = [e.clientX, e.clientY];
                    element.style.top = `${element.offsetTop - pos2}px`;
                    element.style.left = `${element.offsetLeft - pos1}px`;
                };
            };
        }
    };

    const LotteryManager = {
        processedTopics: [],

        async fetchLotteryTopics() {
            try {
                const response = await fetch(Config.FETCH_URL);
                const data = await response.json();
                return data.topic_list.topics;
            } catch (error) {
                console.error('获取抽奖主题时出错:', error);
                return [];
            }
        },

        isRecentTopic(topic) {
            return new Date(topic.created_at) >= new Date(Date.now() - Config.ONE_DAY_MS);
        },

        async fetchFirstPost(topicId) {
            try {
                const response = await fetch(`${Config.BASE_URL}/${topicId}/posts.json`);
                const data = await response.json();
                return data.post_stream.posts[0];
            } catch (error) {
                console.error('获取帖子详情时出错:', error);
                return null;
            }
        },

        parseComments(commentText) {
            if (!commentText) return [];
            return commentText.split(' ').filter(comment => comment.trim() !== '');
        },

        getRandomComment(comments) {
            if (comments.length === 0) return '';
            const randomIndex = Math.floor(Math.random() * comments.length);
            return comments[randomIndex];
        },

        async likeAndComment(topic, userComment) {
            if (this.processedTopics.some(t => t.id === topic.id)) return;

            try {
                const firstPost = await this.fetchFirstPost(topic.id);
                if (!firstPost) return;

                const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute('content');

                // 检查是否已经点赞
                const alreadyLiked = firstPost.actions_summary.some(action =>
                    action.id === Config.LIKE_ACTION_ID && action.acted
                );

                // 检查是否已经评论
                const alreadyCommented = firstPost.reply_count > 0;

                let commentSuccess = true;
                let likeSuccess = true;

                // 修复：确保评论内容非空并且在评论前等待一点时间
                if (!alreadyCommented && userComment && userComment.trim() !== '') {
                    // 添加小延时确保请求不会太快
                    await new Promise(resolve => setTimeout(resolve, 300));

                    // 执行评论操作
                    commentSuccess = await this.postComment(topic.id, userComment, csrfToken);
                }

                // 评论后再进行点赞操作
                if (!alreadyLiked) {
                    // 添加小延时确保请求不会太快
                    await new Promise(resolve => setTimeout(resolve, 300));

                    likeSuccess = await this.performReaction(firstPost.id, 'heart', csrfToken);
                }

                this.processedTopics.push({
                    id: topic.id,
                    title: topic.title,
                    slug: topic.slug,
                    success: commentSuccess && likeSuccess,
                    alreadyLiked: alreadyLiked,
                    alreadyCommented: alreadyCommented,
                    usedComment: userComment
                });
                UIManager.updateContent(this.getProcessedTopicsContent());
            } catch (error) {
                console.error('点赞和评论时出错:', error);
                this.processedTopics.push({
                    id: topic.id,
                    title: topic.title,
                    slug: topic.slug,
                    success: false,
                    alreadyLiked: false,
                    alreadyCommented: false,
                    usedComment: userComment
                });
                UIManager.updateContent(this.getProcessedTopicsContent());
            }
        },

        // 新增专门的评论发布方法，确保评论请求格式正确
        async postComment(topicId, commentText, csrfToken) {
            try {
                console.log(`发送评论到帖子 ${topicId}: ${commentText}`);

                const response = await fetch(Config.POSTS_URL, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-CSRF-Token': csrfToken,
                        'Accept': 'application/json'
                    },
                    body: JSON.stringify({
                        raw: commentText,
                        topic_id: topicId,
                        reply_to_post_number: null,
                        category: null,
                        archetype: "regular",
                        nested_post: false
                    })
                });

                if (!response.ok) {
                    const errorData = await response.json().catch(() => ({}));
                    console.error('评论失败:', errorData);
                    return false;
                }

                return true;
            } catch (error) {
                console.error('发布评论时出错:', error);
                return false;
            }
        },

        async performReaction(postId, reaction, csrfToken) {
            try {
                const response = await fetch(Config.POST_ACTION_URL, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-CSRF-Token': csrfToken,
                        'Accept': 'application/json'
                    },
                    body: JSON.stringify({
                        id: postId,
                        post_action_type_id: Config.LIKE_ACTION_ID,
                        flag_topic: false,
                        reaction: reaction
                    })
                });

                if (!response.ok) {
                    const errorData = await response.json().catch(() => ({}));
                    console.error('点赞失败:', errorData);
                    return false;
                }

                return true;
            } catch (error) {
                console.error('执行点赞操作时出错:', error);
                return false;
            }
        },

        async performAction(url, data, csrfToken) {
            try {
                const response = await fetch(url, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-CSRF-Token': csrfToken,
                        'Accept': 'application/json'
                    },
                    body: JSON.stringify(data)
                });

                if (!response.ok) {
                    const errorData = await response.json().catch(() => ({}));
                    console.error('执行操作失败:', errorData);
                    return false;
                }

                return true;
            } catch (error) {
                console.error('执行操作时出错:', error);
                return false;
            }
        },

        getProcessedTopicsContent() {
            return this.processedTopics.length === 0
                ? '<p>暂无处理过的帖子</p>'
                : this.processedTopics.map(topic =>
                    `<a href="${Config.BASE_URL}/${topic.slug}/${topic.id}" class="topic-link${topic.success ? '' : ' failed'}" target="_blank">
                        ${topic.title}
                        ${topic.alreadyLiked ? ' (已点赞)' : ''}
                        ${topic.alreadyCommented ? ' (已评论)' : ''}
                        ${!topic.alreadyCommented && topic.usedComment ? `<div class="comment-used">评论: ${topic.usedComment.length > 15 ? topic.usedComment.substring(0, 15) + '...' : topic.usedComment}</div>` : ''}
                    </a>`
                  ).join('');
        },

        async start(presetComment = null) {
            // 如果有预设评论（从历史中选择），就直接使用，否则弹出输入框
            let userCommentInput = presetComment;

            if (!userCommentInput) {
                userCommentInput = prompt('请输入评论内容（用空格分隔多条评论，发送时随机选择）：');
                if (!userCommentInput) {
                    alert('未输入评论内容，操作取消');
                    return;
                }

                // 将新输入的评论添加到历史记录
                HistoryManager.addToHistory(userCommentInput);
            }

            const commentsList = this.parseComments(userCommentInput);
            if (commentsList.length === 0) {
                alert('未检测到有效评论，操作取消');
                return;
            }

            const topics = await this.fetchLotteryTopics();
            const recentTopics = topics.filter(this.isRecentTopic);

            // 如果没有找到最近的抽奖帖子
            if (recentTopics.length === 0) {
                alert('未找到最近的抽奖帖子');
                return;
            }

            console.log(`找到 ${recentTopics.length} 个最近的抽奖帖子`);

            // 修改后的处理流程：为每个帖子准备随机评论和延迟，然后再执行互动
            const topicsToProcess = recentTopics.map(topic => {
                return {
                    topic: topic,
                    // 为每个帖子随机选择一条评论
                    randomComment: this.getRandomComment(commentsList),
                    // 生成随机延时（多个帖子时需要）
                    delay: recentTopics.length > 1 ? Math.floor(Math.random() * 2000) + 5000 : 500
                };
            });

            // 显示进度信息
            UIManager.updateContent(`<p>开始处理 ${topicsToProcess.length} 个帖子...</p>`);

            // 顺序处理每个帖子
            for (const item of topicsToProcess) {
                console.log(`处理帖子: ${item.topic.title}, 使用评论: ${item.randomComment}`);

                // 先等待随机延时
                await new Promise(resolve => setTimeout(resolve, item.delay));

                // 然后执行点赞和评论操作
                await this.likeAndComment(item.topic, item.randomComment);
            }

            console.log('所有帖子处理完成');
        }
    };

    function init() {
        StyleManager.injectStyles();
        UIManager.initPopup();
    }

    init();
})();
