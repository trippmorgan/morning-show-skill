sed -i 's/local title_clean=.*/local title_clean=$(echo "$title" | sed "s/\\'\''/\\'\'\\'\''/g")/g' scripts/pull-songs.sh
sed -i 's/local artist_clean=.*/local artist_clean=$(echo "$artist" | sed "s/\\'\''/\\'\'\\'\''/g")/g' scripts/pull-songs.sh
