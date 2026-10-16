#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
// Load the QEMU library next to this binary, never one named by the environment.
int main(int argc,char **argv,char **envp){
 char exe[PATH_MAX],real[PATH_MAX],path[PATH_MAX];uint32_t size=sizeof exe;
 if(_NSGetExecutablePath(exe,&size)||!realpath(exe,real))return 1;
 if(snprintf(path,sizeof path,"%s/qemu-aarch64-softmmu",dirname(real))>=(int)sizeof path)return 1;
 void *lib=dlopen(path,RTLD_LOCAL|RTLD_LAZY);
 if(!lib){fprintf(stderr,"%s\n",dlerror());return 1;}
 void (*init)(int,char**,char**)=dlsym(lib,"qemu_init");
 void (*loop)(void)=dlsym(lib,"qemu_main_loop");
 void (*cleanup)(void)=dlsym(lib,"qemu_cleanup");
 if(!init||!loop||!cleanup)return 2;
 init(argc,argv,envp);loop();cleanup();return 0;
}
