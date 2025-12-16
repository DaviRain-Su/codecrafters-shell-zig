echo hello > test_echo.txt
cat test_echo.txt
echo "world" 1> test_echo_2.txt
cat test_echo_2.txt
ls -1 src > ls_out.txt
cat ls_out.txt
echo "error_msg" 2> test_stderr.txt
cat test_stderr.txt
echo "line1" > test_append.txt
echo "line2" >> test_append.txt
cat test_append.txt
echo "new_append" >> test_append_new.txt
cat test_append_new.txt
rm test_echo.txt test_echo_2.txt ls_out.txt test_stderr.txt test_append.txt test_append_new.txt