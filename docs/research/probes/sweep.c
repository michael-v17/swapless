#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <time.h>
pid_t responsibility_get_pid_responsible_for_pid(pid_t);
struct pcoal { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };
int main(int argc, char **argv) {
  struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
  struct rusage self0; getrusage(RUSAGE_SELF, &self0);
  int n = proc_listallpids(NULL, 0); pid_t *pids = calloc(n + 64, sizeof(pid_t));
  n = proc_listallpids(pids, (n + 64) * sizeof(pid_t));
  int ok = 0, eperm = 0; uint64_t total = 0;
  for (int i = 0; i < n; i++) {
    pid_t pid = pids[i]; struct rusage_info_v4 ri; struct pcoal c = {0};
    int r = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t*)&ri);
    proc_pidinfo(pid, 20, 0, &c, sizeof c);
    pid_t rp = responsibility_get_pid_responsible_for_pid(pid);
    struct proc_bsdshortinfo si; int s = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si);
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0}; proc_pidpath(pid, path, sizeof path);
    if (r == 0) { ok++; total += ri.ri_phys_footprint; } else if (errno == EPERM) eperm++;
    if (argc > 1) printf("%d\t%d\t%d\t%llu\t%llu\t%.1f\t%s\n", pid, s>0?si.pbsi_ppid:-1, rp, c.coalition_id[0], c.coalition_id[1], r==0?ri.ri_phys_footprint/1048576.0:-1.0, path);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1); struct rusage self1; getrusage(RUSAGE_SELF, &self1);
  double cpu = (self1.ru_utime.tv_sec-self0.ru_utime.tv_sec)+(self1.ru_utime.tv_usec-self0.ru_utime.tv_usec)/1e6+(self1.ru_stime.tv_sec-self0.ru_stime.tv_sec)+(self1.ru_stime.tv_usec-self0.ru_stime.tv_usec)/1e6;
  fprintf(stderr, "pids=%d readable=%d eperm=%d sum_footprint_readable=%.2fGB wall=%.1fms cpu=%.1fms\n", n, ok, eperm, total/1073741824.0, (t1.tv_sec-t0.tv_sec)*1e3+(t1.tv_nsec-t0.tv_nsec)/1e6, cpu*1e3);
  return 0;
}
