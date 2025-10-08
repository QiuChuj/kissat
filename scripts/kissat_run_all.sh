for file in /home/richard/project/SAT_benchmark/1_min_timeout/*; do
    if [ -f "$file" ]; then
        /home/richard/project/kissat/build/kissat $file
    fi
done