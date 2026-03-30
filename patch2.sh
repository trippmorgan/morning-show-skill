sed -i 's/uid=$(echo "$uid" | xargs)/uid="${uid#"${uid%%[![:space:]]*}\"}"; uid="${uid%"${uid##*[![:space:]]}"}"/g' scripts/pull-songs.sh
sed -i 's/title=$(echo "$title" | xargs)/title="${title#"${title%%[![:space:]]*}\"}"; title="${title%"${title##*[![:space:]]}"}"/g' scripts/pull-songs.sh
sed -i 's/artist=$(echo "$artist" | xargs)/artist="${artist#"${artist%%[![:space:]]*}\"}"; artist="${artist%"${artist##*[![:space:]]}"}"/g' scripts/pull-songs.sh
sed -i 's/filename=$(echo "$filename" | xargs)/filename="${filename#"${filename%%[![:space:]]*}\"}"; filename="${filename%"${filename##*[![:space:]]}"}"/g' scripts/pull-songs.sh
sed -i 's/u=$(echo "$u" | xargs)/u="${u#"${u%%[![:space:]]*}\"}"; u="${u%"${u##*[![:space:]]}"}"/g' scripts/pull-songs.sh
sed -i 's/entry=$(echo "$entry" | xargs)/entry="${entry#"${entry%%[![:space:]]*}\"}"; entry="${entry%"${entry##*[![:space:]]}"}"/g' scripts/pull-songs.sh
