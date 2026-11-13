/* SPDX-License-Identifier: GPL-2.0 */
#ifndef KSU_SUSFS_COMPAT_V2_H
#define KSU_SUSFS_COMPAT_V2_H
/*
 * Bridge SukiSU-Ultra's builtin SUSFS v2.x client to kernel-side SUSFS v1.5.5
 * (susfs4ksu kernel-4.19 branch, non-GKI).
 *
 * Defines the v2.4.0 command numbers and struct layouts the SukiSU manager
 * speaks, declares the bridge functions implemented in fs/susfs_compat_v2.c,
 * and mirrors v2's static-inline task-state helpers on top of 1.5.5's
 * task_struct bit (TASK_STRUCT_NON_ROOT_USER_APP_PROC).
 *
 * Only included by KernelSU sources (kernel_includes.h). v2-only kernel
 * features (SUS_MAP, priority uid filter, AVC log spoofing, enabled-features
 * report) degrade to -ENOTSUPP.
 */
#include <linux/version.h>
#include <linux/types.h>
#include <linux/cred.h>
#include <linux/sched.h>
#include <linux/thread_info.h>
#include <linux/workqueue.h>

/* ---- v2.4.0 command numbers missing from 1.5.5 headers ---- */
#ifndef SUSFS_MAGIC
#define SUSFS_MAGIC 0xFAFAFAFA
#endif
#ifndef CMD_SUSFS_ADD_SUS_PATH_LOOP
#define CMD_SUSFS_ADD_SUS_PATH_LOOP 0x55553
#endif
#ifndef CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS
#define CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS 0x55561
#endif
#ifndef CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING
#define CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING 0x60010
#endif
#ifndef CMD_SUSFS_ADD_SUS_MAP
#define CMD_SUSFS_ADD_SUS_MAP 0x60020
#endif
#ifndef CMD_SUSFS_SET_PRIORITY_UID_FILTER
#define CMD_SUSFS_SET_PRIORITY_UID_FILTER 0x60030
#endif
#ifndef SUSFS_ENABLED_FEATURES_SIZE
#define SUSFS_ENABLED_FEATURES_SIZE 8192
#endif
#ifndef SUSFS_APP_STR_BUF_SIZE
#define SUSFS_APP_STR_BUF_SIZE 65535
#endif

/* ---- v2 struct layouts (must byte-match the SukiSU manager) ---- */
struct st_susfs_sus_path_v2 {
	char                                    target_pathname[256];
	int                                     err;
};

struct st_susfs_hide_sus_mnts_v2 {
	bool                                    enabled;
	int                                     err;
};

struct st_susfs_sus_kstat_v2 {
	bool                                    is_statically;
	unsigned long                           target_ino;
	char                                    target_pathname[256];
	unsigned long                           spoofed_ino;
	unsigned long                           spoofed_dev;
	unsigned int                            spoofed_nlink;
	long long                               spoofed_size;
	long                                    spoofed_atime_tv_sec;
	unsigned long                           spoofed_atime_tv_nsec;
	long                                    spoofed_mtime_tv_sec;
	unsigned long                           spoofed_mtime_tv_nsec;
	long                                    spoofed_ctime_tv_sec;
	unsigned long                           spoofed_ctime_tv_nsec;
	long long                               spoofed_blocks;
	long                                    spoofed_blksize;
	int                                     flags;
	int                                     err;
};

struct st_susfs_uname_v2 {
	char                                    release[65];
	char                                    version[65];
	int                                     err;
};

struct st_susfs_log_v2 {
	bool                                    enabled;
	int                                     err;
};

struct st_susfs_spoof_cmdline_or_bootconfig_v2 {
	char                                    fake_cmdline_or_bootconfig[8192];
	int                                     err;
};

struct st_susfs_open_redirect_v2 {
	char                                    target_pathname[256];
	char                                    redirected_pathname[256];
	int                                     uid_scheme;
	int                                     err;
};

struct st_susfs_sus_map_v2 {
	char                                    target_pathname[256];
	int                                     err;
};

struct st_susfs_priority_uid_filter_v2 {
	char                                    app_strings[SUSFS_APP_STR_BUF_SIZE];
	int                                     err;
};

struct st_susfs_avc_log_spoofing_v2 {
	bool                                    enabled;
	int                                     err;
};

struct st_susfs_enabled_features_v2 {
	char                                    enabled_features[SUSFS_ENABLED_FEATURES_SIZE];
	int                                     err;
};

struct st_susfs_variant_v2 {
	char                                    susfs_variant[16];
	int                                     err;
};

struct st_susfs_version_v2 {
	char                                    susfs_version[16];
	int                                     err;
};

/* ---- v2-signature bridge functions (implemented in fs/susfs_compat_v2.c) ---- */
void susfs_add_sus_path(void __user **user_info);
void susfs_add_sus_path_loop(void __user **user_info);
void susfs_set_hide_sus_mnts_for_non_su_procs(void __user **user_info);
void susfs_add_sus_kstat(void __user **user_info);
void susfs_update_sus_kstat(void __user **user_info);
void susfs_set_uname(void __user **user_info);
void susfs_enable_log(void __user **user_info);
void susfs_set_cmdline_or_bootconfig(void __user **user_info);
void susfs_add_open_redirect(void __user **user_info);
void susfs_add_sus_map(void __user **user_info);
void susfs_set_priority_uid_filter(void __user **user_info);
void susfs_set_avc_log_spoofing(void __user **user_info);
void susfs_get_enabled_features(void __user **user_info);
void susfs_show_variant(void __user **user_info);
void susfs_show_version(void __user **user_info);
void susfs_start_sdcard_monitor_fn(void);
void susfs_parse_priority_app_strings(void);
int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type, u16 type, u32 orig_avd_allowed);
int susfs_add_sus_type(const char *secctx, u32 type_value);
extern struct work_struct susfs_extra_works;

/* ---- v2 static-inline helpers, ported to 1.5.5 task_struct bits ---- */
static inline bool susfs_starts_with(const char *str, const char *prefix)
{
	while (*prefix) {
		if (*str++ != *prefix++)
			return false;
	}
	return true;
}

static inline bool susfs_ends_with(const char *str, const char *suffix)
{
	size_t str_len, suffix_len;

	if (!str || !suffix)
		return false;

	str_len = strlen(str);
	suffix_len = strlen(suffix);

	if (suffix_len > str_len)
		return false;

	return !strcmp(str + str_len - suffix_len, suffix);
}

static inline bool susfs_is_current_app_uid(void)
{
	return ((current_uid().val % 100000) >= 10000);
}

/* 1.5.5 has no per-task umounted state: try_umount works by uid instead. */
static inline bool susfs_is_current_proc_umounted(void)
{
	return false;
}

static inline void susfs_set_current_proc_umounted(void)
{
}

static inline void susfs_clear_current_proc_umounted(void)
{
}

static inline bool susfs_is_current_proc_umounted_for_zygote_next(void)
{
	return false;
}

static inline void susfs_set_current_proc_umounted_for_zygote_next(void)
{
}

static inline void susfs_clear_current_proc_umounted_for_zygote_next(void)
{
}

static inline bool susfs_is_current_proc_umounted_app(void)
{
	return false;
}

/* 1.5.5's non-root-app bit lives in task_struct.susfs_task_state */
#ifdef CONFIG_KSU_SUSFS
static inline bool susfs_is_current_proc_no_su(void)
{
	return unlikely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC);
}

static inline void susfs_set_current_proc_no_su(void)
{
	current->susfs_task_state |= TASK_STRUCT_NON_ROOT_USER_APP_PROC;
}

static inline void susfs_clear_current_proc_no_su(void)
{
	current->susfs_task_state &= ~TASK_STRUCT_NON_ROOT_USER_APP_PROC;
}
#else
static inline bool susfs_is_current_proc_no_su(void) { return false; }
static inline void susfs_set_current_proc_no_su(void) {}
static inline void susfs_clear_current_proc_no_su(void) {}
#endif

#endif /* KSU_SUSFS_COMPAT_V2_H */
