#pragma once
#include <stdint.h>
int sino_smc_init(void);
void sino_smc_shutdown(void);
/* Fills rpm[] and maxrpm[] (up to cap). Returns fan count, 0 on failure. */
int sino_smc_fans(float *rpm, float *maxrpm, int cap);
int sino_smc_temps(char *names32, float *celsius, int cap);
int sino_pid_energy_nj(int pid, uint64_t *nanojoules);
int sino_pid_footprint(int pid, uint64_t *bytes);
