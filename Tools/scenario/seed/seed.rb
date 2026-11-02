# シナリオのMastodonに、使う人のアカウントと、相手役の人、投稿、通知になるやりとりを流し込む。
# setup.shが空のデータベースに1回だけ`rails runner`で走らせ、終わった状態をスナップショットにする。何度も走らせる前提にはしない。
# パスワードはこのローカルのサーバーだけのテスト用の値。
require 'zlib'
require 'sidekiq/api'

PASSWORD = 'scenario-password'

# 本番モードのMastodonは、メールアドレスのドメインのMXレコードを引いて、ないと作らせない（User.skip_mx_check?が外すのは開発モードだけ）。
# このサーバーのドメインはmastodon.localhostで、コンテナは外へ出られないので、流し込みの間だけ引かないようにする。
User.define_singleton_method(:skip_mx_check?) { true }

# 単色のPNGを書き出す。画像付きの投稿に使う。
def png(path, width, height, rgb)
  row = "\x00".b + rgb.pack('C3') * width
  chunk = ->(type, data) { [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N') }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b +
    chunk.call('IHDR', [width, height, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
    chunk.call('IDAT', Zlib::Deflate.deflate(row * height)) +
    chunk.call('IEND', ''))
  path
end

def person(username, display_name, note)
  account = Account.new(username: username, display_name: display_name, note: note)
  user = User.new(
    email: "#{username}@mastodon.localhost",
    password: PASSWORD,
    agreement: true,
    confirmed_at: Time.now.utc,
    bypass_registration_checks: true,
    locale: 'ja'
  )
  user.account = account
  user.save!
  # 作るときに承認済みにしても、登録の受け付けの設定（既定は承認制）で上書きされる。tootctl accounts create --approveと同じく、作ってから承認する
  user.approve!
  # Mastodonは最近ログインした人のホームにしか投稿を入れず（FeedManager#push_to_home）、初めてのログインではホームを作り直さない。
  # 流し込みの間はログインしたばかりの扱いにして、ホームを埋めておく。スナップショットが古くなっても、ログインのときに作り直される
  user.update_columns(current_sign_in_at: Time.now.utc, last_sign_in_at: Time.now.utc)
  account
end

def post(account, text, **options)
  PostStatusService.new.call(account, text: text, language: 'ja', **options)
end

def media(account, path, description = nil)
  MediaAttachment.create!(account: account, file: File.open(path), description: description).id
end

you = person('you', 'あなた', 'シナリオで使う人のアカウント')
alice = person('alice', 'アリス', 'パンと写真が好き')
bob = person('bob', 'Bob', 'Mastodonを毎日見ている')
carol = person('carol', 'キャロル', '映画の感想を書いています')
dave = person('dave', 'とても長い表示名のアカウントで名前が収まらないかもしれない人', '')

[alice, bob, carol, dave].each { |other| FollowService.new.call(you, other) }
[alice, bob, dave].each { |other| FollowService.new.call(other, you) }

dir = Dir.mktmpdir
colors = [[230, 120, 40], [40, 110, 220], [60, 170, 90], [200, 50, 60]]
images = colors.each_with_index.map { |rgb, index| png("#{dir}/#{index}.png", 1200, index.even? ? 800 : 1200, rgb) }
tall = png("#{dir}/tall.png", 600, 1800, [40, 160, 170])

post(alice, 'おはようございます。駅前のパン屋が開いていたので、久しぶりにクロワッサンを買いました')
post(bob, '散歩で撮った写真', media_ids: images.map { |path| media(bob, path, '単色の写真') })
post(carol, '結末に触れます。最後の場面で、主人公は家に戻らずに駅へ向かいました', spoiler_text: '映画の結末について')
post(alice, '閲覧注意の写真', media_ids: [media(alice, images[0])], sensitive: true)
post(dave, '名前が長い人の投稿です')
post(carol, '縦長の写真', media_ids: [media(carol, tall, '縦に長い写真')])
post(bob, '今日の #scia の話。タイムラインが流れるのを眺めています')
post(alice, '#scia を使ってみた感想を書きます。文字の大きさを変えられるのがいい')
post(carol, '週末に見る映画を決めたい', poll: { options: %w[コメディ ホラー ドキュメンタリー], expires_in: 7 * 24 * 60 * 60, multiple: false })

question = post(bob, '昼ごはんに何を食べるか迷っています')
answer = post(alice, '@bob 駅前のパン屋はどうですか', thread: question)
post(bob, '@alice いいですね、行ってみます', thread: answer)

mine = post(you, 'はじめての投稿です')
FavouriteService.new.call(alice, mine)
FavouriteService.new.call(dave, mine)
ReblogService.new.call(bob, mine)
post(alice, '@you ようこそ', thread: mine)
post(carol, '@you おすすめの映画があれば教えてください')

# ホームの組み立てや通知はSidekiqが行うので、終わるまで待ってからスナップショットにする。
# メールはSMTP_DELIVERY_METHOD=testで送らないので、再試行に溜まる仕事はない。予約の仕事（投票の締め切りなど）は待たない。
deadline = Time.now + 120
until Sidekiq::Stats.new.enqueued.zero? && Sidekiq::Workers.new.size.zero?
  raise 'Sidekiqの仕事が120秒で終わらなかった' if Time.now > deadline

  sleep 1
end
raise "Sidekiqの仕事が失敗した: #{Sidekiq::RetrySet.new.map(&:display_class).uniq.join(', ')}" unless Sidekiq::RetrySet.new.size.zero?

puts 'seeded'
