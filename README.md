## 功能介绍  
  
当 Claude Code 执行任务时，通过企业微信机器人向指定群聊发送消息提醒，支持以下场景：  
  
| 场景   | 消息标题                | 触发条件                 |     |
| ---- | ------------------- | -------------------- | --- |
| 代码提交 | `${PROJECT}任务完成 ✅`  | 最近 5 分钟内有 git commit |     |
| 需要授权 | `${PROJECT}任务中断 🛑` | Claude 执行命令需要用户授权/确认 |     |
  
**去重机制**：同一个项目，同一种提醒，5 分钟内只发一次，避免消息轰炸。  
  
---  
  
## 安装步骤  
  
### 1. 获取企业微信机器人 Webhook URL  
1. 在企业微信群中，点击右上角「...」→「添加群机器人」  
2. 创建机器人后，复制 Webhook 地址  
   - 格式如：`https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxx`  
  
### 2. 配置环境变量  
  
编辑 Claude Code 全局配置文件 `~/.claude/settings.json`，在 `env` 中添加：  
  
```json  
{  
  "env": {  
    "WECOM_WEBHOOK_URL": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=你的key"  
  }  
}  
```  
  
### 3. 配置 Hooks  
在同一文件 `~/.claude/settings.json` 中，添加 `hooks` 字段：  
  
```json  
{  
  "hooks": {  
    "Stop": [  
      {  
        "hooks": [  
          {  
            "type": "command",  
            "command": "bash ~/.claude/hooks/send-wecom.sh",  
            "timeout": 15,  
            "statusMessage": "Sending WeCom notification..."  
          }  
        ]  
      }  
    ],  
    "Notification": [  
      {  
        "hooks": [  
          {  
            "type": "command",  
            "command": "bash ~/.claude/hooks/send-wecom.sh",  
            "timeout": 15,  
            "statusMessage": "Sending WeCom notification..."  
          }  
        ]  
      }  
    ]  
  }  
}  
```  
  
### 4. 放置脚本  
  
将 `send-wecom.sh` 脚本放到 `~/.claude/hooks/` 目录下：  
  
```bash  
mkdir -p ~/.claude/hooks  
chmod +x ~/.claude/hooks/send-wecom.sh  
```  
  
脚本路径必须与 `settings.json` 中的 `command` 配置一致。  
  
### 5. 重启 Claude Code  
配置修改后，需要**重启 Claude Code 会话**才能生效。在 Claude Code 中执行：  
  
```  
/hooks  
```  
  
确认 `Stop` 和 `Notification` 显示为 **active**。  
  
---  
  
## 消息格式  
  
### 任务完成（代码提交）  
  
```  
persona-flow任务完成 ✅  
完成时间：04-27 12:00:00  
执行用时：3分25秒  
任务总结：feat(scope): 添加登录功能  
```  
  
### 任务中断（需要授权）  
  
```  
persona-flow任务中断 🛑  
完成时间：04-27 12:05:00  
执行用时：5分10秒  
任务总结：Claude Code 需要您的注意/授权，请查看终端  
```  
  
---  
  
## 常见问题  
  
### Q1: 没有收到任何消息  
  
1. 检查 `~/.claude/settings.json` 中的 `WECOM_WEBHOOK_URL` 是否正确  
2. 在 Claude Code 中执行 `/hooks`，确认 `Stop` 和 `Notification` 为 **active**3. 确认脚本路径正确且文件存在：`ls -la ~/.claude/hooks/send-wecom.sh`  
3. 确认脚本有执行权限：`chmod +x ~/.claude/hooks/send-wecom.sh`  
4. 如果刚刚修改了配置，需要**重启 Claude Code 会话**  
  
### Q2: 消息重复发送  
  
脚本已内置去重机制（5 分钟窗口）。如果仍然重复：  
  
1. 检查是否有多个 Claude Code 会话同时运行  
2. 查看去重文件是否存在：`ls /tmp/claude-wecom-dedup-*`  
3. 手动清理去重缓存：`rm -f /tmp/claude-wecom-dedup-*`  
  
### Q3: 项目标题显示错误  
  
脚本优先从 hook payload 的 `cwd` 字段获取项目名。如果 `cwd` 缺失，会通过 `session_id` 查找 session 文件补全。确保 `~/.claude/sessions/` 目录下的 session 文件正常生成。  
  
### Q4: 只收到 commit 消息，收不到授权消息  
  
1. 确认 `settings.json` 中配置了 `Notification` hook2. 授权消息只在 Claude 执行命令需要用户批准时触发（如 Bash 命令权限弹窗）  
2. 某些工具调用可能不需要显式授权，因此不会触发  
  
### Q5: 消息发送有延迟  
  
脚本的 `timeout` 设置为 15 秒。如果网络较慢，可以在 `settings.json` 中适当调大 `timeout` 值。  
  
---  
  
## 调试方法  
  
脚本运行日志保存在以下位置：  
  
```bash  
# 查看 hook 触发记录  
cat /tmp/claude-hook-debug.log  
  
# 查看去重文件  
ls -la /tmp/claude-wecom-dedup-*  
```  
  
如需进一步排查，可以临时在脚本中添加 `echo` 输出到日志文件。  
  
---  
  
## 安全提示  
  
- `WECOM_WEBHOOK_URL` 包含机器人密钥，**不要提交到 Git 仓库**  
- `~/.claude/settings.json` 通常不会进 git，但仍建议检查 `.gitignore`- Webhook URL 泄露后，任何人都能往群里发消息。如怀疑泄露，请在企业微信中删除并重新创建机器人
