echo hello > test_echo.txt
cat test_echo.txt
echo "world" 1> test_echo_2.txt
cat test_echo_2.txt
ls -1 src > ls_out.txt
cat ls_out.txt
echo "error_msg" 2> test_stderr.txt
cat test_stderr.txt
rm test_echo.txt test_echo_2.txt ls_out.txt test_stderr.txt
