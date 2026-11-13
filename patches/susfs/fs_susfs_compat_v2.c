// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS v2.x <-> v1.5.5 bridge for SukiSU-Ultra (builtin) on pre-GKI kernels.
 *
 * Implements the v2 supercall surface the SukiSU manager speaks, on top of
 * susfs4ksu kernel-4.19 (v1.5.5). The 1.5.5 user-facing functions were renamed
 * to susfs155_* by the build scripts; the bridges marshal the v2 struct
 * layouts into the 1.5.5 layouts and call them with set_fs(KERNEL_DS) so they
 * can read kernel-memory structs via their internal copy_from_user().
 *
 * v2-only kernel features (SUS_MAP, priority uid filter, AVC log spoofing,
 * enabled-features report) degrade to -ENOTSUPP.
 */
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs.h>
#include <linux/susfs_compat_v2.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/workqueue.h>

static void ksu155_extra_work_noop(struct work_struct *work)
{
	(void)work;
}

DEFINE_WORK(susfs_extra_works, ksu155_extra_work_noop);

static void ksu155_write_err(void __user *ui, size_t err_offset, int err)
{
	if (ui)
		copy_to_user((char __user *)ui + err_offset, &err, sizeof(err));
}

void susfs_start_sdcard_monitor_fn(void)
{
	/* v2 sdcard monitor: not applicable to 1.5.5 */
}

void susfs_parse_priority_app_strings(void)
{
	/* v2 priority uid filter: not supported on 1.5.5 */
}

int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type, u16 type, u32 orig_avd_allowed)
{
	(void)s_type; (void)t_type; (void)type; (void)orig_avd_allowed;
	return -ENOTSUPP;
}

int susfs_add_sus_type(const char *secctx, u32 type_value)
{
	(void)secctx; (void)type_value;
	return -ENOTSUPP;
}

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
static int ksu155_resolve_target_ino(const char *pathname, unsigned long *out_ino)
{
	struct path p;
	struct inode *inode;

	if (kern_path(pathname, 0, &p))
		return -ENOENT;
	inode = d_backing_inode(p.dentry);
	if (!inode) {
		path_put(&p);
		return -ENOENT;
	}
	*out_ino = inode->i_ino;
	path_put(&p);
	return 0;
}

static void ksu155_add_sus_path_impl(void __user **user_info)
{
	struct st_susfs_sus_path_v2 v = {0};
	struct st_susfs_sus_path legacy = {0};
	mm_segment_t old_fs;
	void __user *ui = *user_info;
	int ret, err = -ENOENT;

	if (copy_from_user(&v, ui, sizeof(v)))
		err = -EFAULT;
	else if (!v.target_pathname[0])
		err = -EINVAL;
	else if (!ksu155_resolve_target_ino(v.target_pathname, &legacy.target_ino))
		err = -ENOENT;
	else {
		strscpy(legacy.target_pathname, v.target_pathname, SUSFS_MAX_LEN_PATHNAME);
		old_fs = get_fs();
		set_fs(KERNEL_DS);
		ret = susfs155_add_sus_path((struct st_susfs_sus_path __user *)&legacy);
		set_fs(old_fs);
		err = ret ? -EINVAL : 0;
	}
	ksu155_write_err(ui, offsetof(struct st_susfs_sus_path_v2, err), err);
}
#endif /* CONFIG_KSU_SUSFS_SUS_PATH */

void susfs_add_sus_path(void __user **user_info)
{
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	ksu155_add_sus_path_impl(user_info);
#endif
}

void susfs_add_sus_path_loop(void __user **user_info)
{
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	/* 1.5.5 has no deferred loop: apply immediately, one path per call. */
	ksu155_add_sus_path_impl(user_info);
#endif
}

void susfs_set_hide_sus_mnts_for_non_su_procs(void __user **user_info)
{
	/* 1.5.5 hides sus mounts from non-su processes by design */
	ksu155_write_err(*user_info, offsetof(struct st_susfs_hide_sus_mnts_v2, err), 0);
}

void susfs_add_sus_kstat(void __user **user_info)
{
	void __user *ui = *user_info;
	int err = -ENOTSUPP;
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	struct st_susfs_sus_kstat_v2 v = {0};
	struct st_susfs_sus_kstat legacy = {0};
	mm_segment_t old_fs;
	int ret;

	err = -EFAULT;
	if (!copy_from_user(&v, ui, sizeof(v))) {
		legacy.is_statically = v.is_statically ? 1 : 0;
		legacy.target_ino = v.target_ino;
		strscpy(legacy.target_pathname, v.target_pathname, SUSFS_MAX_LEN_PATHNAME);
		legacy.spoofed_ino = v.spoofed_ino;
		legacy.spoofed_dev = v.spoofed_dev;
		legacy.spoofed_nlink = v.spoofed_nlink;
		legacy.spoofed_size = v.spoofed_size;
		legacy.spoofed_atime_tv_sec = v.spoofed_atime_tv_sec;
		legacy.spoofed_atime_tv_nsec = (long)v.spoofed_atime_tv_nsec;
		legacy.spoofed_mtime_tv_sec = v.spoofed_mtime_tv_sec;
		legacy.spoofed_mtime_tv_nsec = (long)v.spoofed_mtime_tv_nsec;
		legacy.spoofed_ctime_tv_sec = v.spoofed_ctime_tv_sec;
		legacy.spoofed_ctime_tv_nsec = (long)v.spoofed_ctime_tv_nsec;
		legacy.spoofed_blksize = v.spoofed_blksize;
		legacy.spoofed_blocks = v.spoofed_blocks;
		old_fs = get_fs();
		set_fs(KERNEL_DS);
		ret = susfs155_add_sus_kstat((struct st_susfs_sus_kstat __user *)&legacy);
		set_fs(old_fs);
		err = ret ? -EINVAL : 0;
	}
#endif
	ksu155_write_err(ui, offsetof(struct st_susfs_sus_kstat_v2, err), err);
}

void susfs_update_sus_kstat(void __user **user_info)
{
	void __user *ui = *user_info;
	int err = -ENOTSUPP;
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	struct st_susfs_sus_kstat_v2 v = {0};
	struct st_susfs_sus_kstat legacy = {0};
	mm_segment_t old_fs;
	int ret;

	err = -EFAULT;
	if (!copy_from_user(&v, ui, sizeof(v))) {
		legacy.is_statically = v.is_statically ? 1 : 0;
		legacy.target_ino = v.target_ino;
		strscpy(legacy.target_pathname, v.target_pathname, SUSFS_MAX_LEN_PATHNAME);
		legacy.spoofed_ino = v.spoofed_ino;
		legacy.spoofed_dev = v.spoofed_dev;
		legacy.spoofed_nlink = v.spoofed_nlink;
		legacy.spoofed_size = v.spoofed_size;
		legacy.spoofed_atime_tv_sec = v.spoofed_atime_tv_sec;
		legacy.spoofed_atime_tv_nsec = (long)v.spoofed_atime_tv_nsec;
		legacy.spoofed_mtime_tv_sec = v.spoofed_mtime_tv_sec;
		legacy.spoofed_mtime_tv_nsec = (long)v.spoofed_mtime_tv_nsec;
		legacy.spoofed_ctime_tv_sec = v.spoofed_ctime_tv_sec;
		legacy.spoofed_ctime_tv_nsec = (long)v.spoofed_ctime_tv_nsec;
		legacy.spoofed_blksize = v.spoofed_blksize;
		legacy.spoofed_blocks = v.spoofed_blocks;
		old_fs = get_fs();
		set_fs(KERNEL_DS);
		ret = susfs155_update_sus_kstat((struct st_susfs_sus_kstat __user *)&legacy);
		set_fs(old_fs);
		err = ret ? -EINVAL : 0;
	}
#endif
	ksu155_write_err(ui, offsetof(struct st_susfs_sus_kstat_v2, err), err);
}

void susfs_set_uname(void __user **user_info)
{
	void __user *ui = *user_info;
	int err = -ENOTSUPP;
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	struct st_susfs_uname_v2 v = {0};
	struct st_susfs_uname legacy = {0};
	mm_segment_t old_fs;
	int ret;

	err = -EFAULT;
	if (!copy_from_user(&v, ui, sizeof(v))) {
		strscpy(legacy.release, v.release, __NEW_UTS_LEN + 1);
		strscpy(legacy.version, v.version, __NEW_UTS_LEN + 1);
		old_fs = get_fs();
		set_fs(KERNEL_DS);
		ret = susfs155_set_uname((struct st_susfs_uname __user *)&legacy);
		set_fs(old_fs);
		err = ret ? -EINVAL : 0;
	}
#endif
	ksu155_write_err(ui, offsetof(struct st_susfs_uname_v2, err), err);
}

void susfs_enable_log(void __user **user_info)
{
	void __user *ui = *user_info;
	int err = -ENOTSUPP;
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	struct st_susfs_log_v2 v = {0};

	if (copy_from_user(&v, ui, sizeof(v))) {
		err = -EFAULT;
	} else {
		susfs_set_log(v.enabled);
		err = 0;
	}
#endif
	ksu155_write_err(ui, offsetof(struct st_susfs_log_v2, err), err);
}

void susfs_set_cmdline_or_bootconfig(void __user **user_info)
{
	void __user *ui = *user_info;
	int err;
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	/* v2 struct starts with the cmdline text; 1.5.5 copies 4095 bytes from it. */
	err = susfs155_set_cmdline_or_bootconfig((char __user *)ui);
#else
	err = -ENOTSUPP;
#endif
	ksu155_write_err(ui, offsetof(struct st_susfs_spoof_cmdline_or_bootconfig_v2, err), err);
}

void susfs_add_open_redirect(void __user **user_info)
{
	void __user *ui = *user_info;
	int err = -ENOTSUPP;
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	struct st_susfs_open_redirect_v2 v = {0};
	struct st_susfs_open_redirect legacy = {0};
	mm_segment_t old_fs;
	int ret;

	err = -EFAULT;
	if (!copy_from_user(&v, ui, sizeof(v))) {
		err = -ENOENT;
		if (!ksu155_resolve_target_ino(v.target_pathname, &legacy.target_ino)) {
			strscpy(legacy.target_pathname, v.target_pathname, SUSFS_MAX_LEN_PATHNAME);
			strscpy(legacy.redirected_pathname, v.redirected_pathname, SUSFS_MAX_LEN_PATHNAME);
			old_fs = get_fs();
			set_fs(KERNEL_DS);
			ret = susfs155_add_open_redirect((struct st_susfs_open_redirect __user *)&legacy);
			set_fs(old_fs);
			err = ret ? -EINVAL : 0;
		}
	}
#endif
	ksu155_write_err(ui, offsetof(struct st_susfs_open_redirect_v2, err), err);
}

void susfs_add_sus_map(void __user **user_info)
{
	/* v2-only feature */
	ksu155_write_err(*user_info, offsetof(struct st_susfs_sus_map_v2, err), -ENOTSUPP);
}

void susfs_set_priority_uid_filter(void __user **user_info)
{
	/* v2-only feature */
	ksu155_write_err(*user_info, offsetof(struct st_susfs_priority_uid_filter_v2, err), -ENOTSUPP);
}

void susfs_set_avc_log_spoofing(void __user **user_info)
{
	/* v2-only feature */
	ksu155_write_err(*user_info, offsetof(struct st_susfs_avc_log_spoofing_v2, err), -ENOTSUPP);
}

void susfs_get_enabled_features(void __user **user_info)
{
	/* v2-only report format */
	ksu155_write_err(*user_info, offsetof(struct st_susfs_enabled_features_v2, err), -ENOTSUPP);
}

void susfs_show_variant(void __user **user_info)
{
	struct st_susfs_variant_v2 v = {0};

	strscpy(v.susfs_variant, SUSFS_VARIANT, sizeof(v.susfs_variant));
	if (*user_info)
		copy_to_user(*user_info, &v, sizeof(v));
}

void susfs_show_version(void __user **user_info)
{
	struct st_susfs_version_v2 v = {0};

	strscpy(v.susfs_version, SUSFS_VERSION, sizeof(v.susfs_version));
	if (*user_info)
		copy_to_user(*user_info, &v, sizeof(v));
}
