sed -i '/# --- helpers ---/a \trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; echo "$s"; }' scripts/pull-songs.sh
sed -i 's/uid=$(echo "$uid" | xargs)/uid=$(trim "$uid")/g' scripts/pull-songs.sh
sed -i 's/title=$(echo "$title" | xargs)/title=$(trim "$title")/g' scripts/pull-songs.sh
sed -i 's/artist=$(echo "$artist" | xargs)/artist=$(trim "$artist")/g' scripts/pull-songs.sh
sed -i 's/filename=$(echo "$filename" | xargs)/filename=$(trim "$filename")/g' scripts/pull-songs.sh
sed -i 's/u=$(echo "$u" | xargs)/u=$(trim "$u")/g' scripts/pull-songs.sh
sed -i 's/entry=$(echo "$entry" | xargs)/entry=$(trim "$entry")/g' scripts/pull-songs.sh
