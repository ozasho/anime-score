-- 2026年夏アニメ早見シートからの追加用SQL
-- 既存作品の評価や概要は上書きせず、未登録の作品だけを追加します。
-- 安全のため、anime_score_data が1ユーザー分だけの場合に実行されます。
-- Sources checked on 2026-10-03:
-- https://anime-jaadugar.com/sample-page/
-- https://yanisuu.com/
-- https://www.liargame-anime.com/

with database_state as (
  select count(*)::int as user_row_count
  from public.anime_score_data
),
target_row as (
  select user_id, data, updated_at
  from public.anime_score_data
  where (select user_row_count from database_state) = 1
  limit 1
),
current_max as (
  select coalesce(max((item ->> 'num')::int), 0) as max_num
  from target_row
  left join lateral jsonb_array_elements(target_row.data) as item on true
),
incoming(ord, title, aliases, year, watched_year, genres, synopsis) as (
  values
    (
      1,
      '天幕のジャードゥーガル',
      '["天幕のジャードゥーガル"]'::jsonb,
      '2026',
      '2026',
      '["ファンタジー", "その他"]'::jsonb,
      '故郷と大切な人々をモンゴル帝国に奪われた少女シタラが、学んだ知恵を武器にファーティマと名乗り、帝国を内側から崩すため王族へ接近する歴史ドラマ。帝国への恨みを抱く第六妃ドレゲネとの出会いが、二人の復讐と運命を大きく動かしていく。'
    ),
    (
      2,
      'スーパーの裏でヤニ吸うふたり',
      '["スーパーの裏でヤニ吸うふたり", "ヤニ吸う二人", "ヤニ吸うふたり"]'::jsonb,
      '2026',
      '2026',
      '["ラブコメ", "日常系", "恋愛"]'::jsonb,
      '仕事に疲れた会社員・佐々木のささやかな癒やしは、行きつけのスーパーで働く山田さんの笑顔。ある夜、店の裏で煙草を吸う場所を探していた彼は、少し風変わりな女性・田山に声をかけられ、喫煙所で何気ない会話を重ねるようになる。'
    ),
    (
      3,
      'LIAR GAME',
      '["LIAR GAME", "ライアーゲーム", "Liar Game"]'::jsonb,
      '2026',
      '2026',
      '["ミステリー", "その他"]'::jsonb,
      '正直者の女子大生・カンザキナオは、突然届いた1億円と招待状によって、嘘と駆け引きで大金を奪い合う「ライアーゲーム」に巻き込まれる。窮地に陥ったナオは、鋭い洞察力を持つ元天才詐欺師・アキヤマシンイチと手を組み、危険な心理戦へ挑んでいく。'
    )
),
filtered as (
  select
    incoming.*,
    row_number() over (order by incoming.ord) as add_num
  from incoming
  cross join target_row
  where not exists (
    select 1
    from jsonb_array_elements(target_row.data) as existing(item)
    where incoming.aliases ? coalesce(existing.item ->> 'title', '')
  )
),
new_items as (
  select
    filtered.ord,
    filtered.title,
    jsonb_build_object(
      'id', ((extract(epoch from clock_timestamp()) * 1000)::bigint + filtered.ord),
      'num', current_max.max_num + filtered.add_num,
      'title', filtered.title,
      'year', filtered.year,
      'watchedYear', filtered.watched_year,
      'genres', filtered.genres,
      'synopsis', filtered.synopsis,
      'comment', '',
      'story', 0,
      'chara', 0,
      'world', 0,
      'emotion', 0,
      'music', 0,
      'visual', 0,
      'score', 0,
      'date', now()
    ) as item
  from filtered
  cross join current_max
),
payload as (
  select
    coalesce(jsonb_agg(item order by ord), '[]'::jsonb) as items,
    coalesce(jsonb_agg(title order by ord), '[]'::jsonb) as added_titles,
    count(*)::int as added_count
  from new_items
),
updated as (
  update public.anime_score_data as d
  set
    data = d.data || payload.items,
    updated_at = now()
  from target_row, payload
  where d.user_id = target_row.user_id
    and payload.added_count > 0
  returning jsonb_array_length(d.data) as total_count, d.updated_at
)
select
  case
    when database_state.user_row_count <> 1 then 'not_updated: expected exactly one user row'
    when payload.added_count = 0 then 'no_change: all titles already exist'
    else 'updated'
  end as status,
  database_state.user_row_count,
  payload.added_count,
  payload.added_titles,
  coalesce(
    (select total_count from updated),
    (select jsonb_array_length(data) from target_row)
  ) as total_count,
  coalesce(
    (select updated_at from updated),
    (select updated_at from target_row)
  ) as updated_at
from database_state
cross join payload;
