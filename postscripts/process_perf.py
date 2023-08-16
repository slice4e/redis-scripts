import os

arr = os.listdir()

print("test,kernel,user,user_top_20")
for file in arr: 
    if "perf.txt" in file: 

        f=open(file,"r")
        lines=f.readlines()
        sum_user=0.0
        sum_kernel=0.0
        top_20=0.0
        count=0
        for line in lines:
            if "[.]" in line: 
                x = line.split()
                sum_user = sum_user + float(x[0].strip('%'))
                count=count +1
                if count == 20: 
                    top_20 = sum_user
            elif "[k]" in line:
                x = line.split()
                sum_kernel = sum_kernel + float(x[0].strip('%'))
        f.close()
        print(file,sum_kernel,sum_user,top_20,sep=",")
