import type { EngineInterface, Register, RenderSurface } from 'claude-code'

// /merge-to-mainのafter:に渡す、このスレッドのセッションIDをコピーする。前提にしたいスレッドで押し、後のスレッドへの合図に貼る
const copySessionId = async ($: EngineInterface, surface?: RenderSurface) => {
  const id = await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')
  if (id === undefined) {
    $.ui.toast('セッションIDを取得できませんでした（CLAUDE_CODE_HOST_SESSION_IDが未設定）')
    return
  }
  const copied = await $.ui.copy({ text: id, surface })
  $.ui.toast(copied.isCopied ? `コピーしました: ${id}` : `コピーできませんでした（${copied.reason}）: ${id}`)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'session-id',
      description: 'このスレッドのセッションID（local_…）をコピーする',
      immediate: true,
    })
    return next(e)
  })

  // textを返すとモデルが読むtranscriptの行になるため、結果はtoastだけで伝える
  on('command.run', { command: 'session-id' }, async $ => {
    await copySessionId($)
    return {}
  })

  // デスクトップアプリは実行中のターンへ打ったコマンドを順番待ちにするため、入力欄を通らないボタンも置く
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const engine = await next(e)
    const { Box, Button } = $.ui.resolve(e)

    return (
      <Box flexDirection="row" gap={1}>
        {engine}
        <Button key="session-id" label="ID" dimColor onPress={press => copySessionId($, press.surface)} />
      </Box>
    )
  })
}
