#pragma once
#include <stdint.h>
#define SINO_HELPER_VERSION 2
int sino_smc_init(void);
void sino_smc_shutdown(void);
int sino_smc_decode_float(const unsigned char *raw, int got, uint32_t data_type, float *out);
/* Fills rpm/minrpm/maxrpm (up to cap). Returns fan count, 0 on failure. */
int sino_smc_fans(float *rpm, float *minrpm, float *maxrpm, int cap);
int sino_smc_temps(char *names32, float *celsius, int cap);
int sino_pid_rusage(int pid, uint64_t *bytes, uint64_t *nanojoules);
int sino_pid_energy_nj(int pid, uint64_t *nanojoules);
int sino_pid_footprint(int pid, uint64_t *bytes);
int sino_fan_ctl_open(void);
void sino_fan_ctl_close(void);
int sino_fan_ctl_auto(void);
int sino_fan_ctl_set(int fan, float rpm);
int sino_fan_ctl_version(void);
