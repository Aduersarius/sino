#pragma once
#include <stdint.h>
int sino_smc_init(void);
void sino_smc_shutdown(void);
/* Fills rpm/minrpm/maxrpm (up to cap). Returns fan count, 0 on failure. */
int sino_smc_fans(float *rpm, float *minrpm, float *maxrpm, int cap);
int sino_smc_temps(char *names32, float *celsius, int cap);
int sino_pid_energy_nj(int pid, uint64_t *nanojoules);
int sino_pid_footprint(int pid, uint64_t *bytes);
int sino_fan_ctl_open(void);
void sino_fan_ctl_close(void);
int sino_fan_ctl_auto(void);
int sino_fan_ctl_set(int fan, float rpm);
