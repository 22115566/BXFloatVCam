//
//  BXFloatMenuController.m  —— 免费版
//
//  与付费版的差异:
//    - 授权 UI 全部移除（无卡密入口、无锁态、无到期提示）
//    - 头部只显示 FREE BUILD + 模块数量
//    - 每个模块永远可用
//

#import "BXFloatMenuController.h"
#import "BXFloatModule.h"
#import "BXFloatStore.h"

static UIColor *BXBG(void)     { return [UIColor colorWithRed:0.07 green:0.09 blue:0.13 alpha:0.96]; }
static UIColor *BXAccent(void) { return [UIColor colorWithRed:0.19 green:0.55 blue:1.00 alpha:1.0]; }
static UIColor *BXDim(void)    { return [UIColor colorWithWhite:0.62 alpha:1.0]; }

@interface BXFloatMenuController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<BXFloatModule *> *rows;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation BXFloatMenuController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = BXBG();
    self.view.layer.cornerRadius = 14;
    self.view.layer.borderWidth = 1;
    self.view.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    self.view.clipsToBounds = YES;

    [self _buildHeader];
    [self _buildTable];
    [self reload];
}

#pragma mark - 头部

- (void)_buildHeader {
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 62)];
    head.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    head.backgroundColor = [UIColor clearColor];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 200, 22)];
    title.text = @"百相 Lite";
    title.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    [head addSubview:title];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, 200, 16)];
    ver.text = @"vcam 1.0.0  ·  free";
    ver.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    ver.textColor = BXDim();
    [head addSubview:ver];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(self.view.bounds.size.width - 44, 14, 32, 32);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [close setTitleColor:BXDim() forState:UIControlStateNormal];
    [close addTarget:self action:@selector(_close) forControlEvents:UIControlEventTouchUpInside];
    [head addSubview:close];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, self.view.bounds.size.width - 32, 12)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _statusLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.5 alpha:1];
    [head addSubview:_statusLabel];

    [self.view addSubview:head];
}

- (void)_buildTable {
    CGFloat y = 66;
    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, y,
                                self.view.bounds.size.width,
                                self.view.bounds.size.height - y)
                                          style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.07];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 52;
    _table.contentInset = UIEdgeInsetsMake(0, 0, 16, 0);
    [self.view addSubview:_table];
}

#pragma mark - 数据

- (void)reload {
    _rows = [[BXFloatRegistry shared] modules];
    [_table reloadData];
    [self _refreshStatus];
}

- (void)_refreshStatus {
    _statusLabel.text = [NSString stringWithFormat:@"FREE BUILD · %lu 个模块",
                         (unsigned long)_rows.count];
}

#pragma mark - 关闭

- (void)_close {
    [UIView animateWithDuration:0.18 animations:^{ self.view.alpha = 0; }
                     completion:^(BOOL d) { [self.view removeFromSuperview]; }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    BXFloatModule *m = _rows[ip.row];
    static NSString *cid = @"BXRow";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *sel = [UIView new];
        sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        cell.selectedBackgroundView = sel;
    }

    cell.textLabel.text = m.title;
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.text = m.subtitle ?: @"";
    cell.detailTextLabel.textColor = BXDim();

    switch (m.kind) {
        case BXModuleKindToggle: {
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            if (![sw isKindOfClass:[UISwitch class]]) {
                sw = [UISwitch new];
                sw.transform = CGAffineTransformMakeScale(0.78, 0.78);
                sw.onTintColor = BXAccent();
                [sw addTarget:self action:@selector(_toggleChanged:)
             forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            }
            sw.tag = ip.row;
            sw.on = m.on;
            break;
        }
        case BXModuleKindSlider: {
            UISlider *sl = (UISlider *)cell.accessoryView;
            if (![sl isKindOfClass:[UISlider class]]) {
                sl = [UISlider new];
                sl.frame = CGRectMake(0, 0, 120, 30);
                sl.minimumTrackTintColor = BXAccent();
                [sl addTarget:self action:@selector(_sliderChanged:)
             forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sl;
            }
            sl.tag = ip.row;
            sl.minimumValue = m.minValue;
            sl.maximumValue = m.maxValue;
            sl.value = m.value;
            cell.detailTextLabel.text = m.displayValue;
            break;
        }
        case BXModuleKindPicker: {
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 110, 30)];
            l.text = m.displayValue;
            l.textAlignment = NSTextAlignmentRight;
            l.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
            l.textColor = BXAccent();
            cell.accessoryView = l;
            break;
        }
        default: {
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
            l.text = @"执行 ›";
            l.textAlignment = NSTextAlignmentRight;
            l.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
            l.textColor = BXAccent();
            cell.accessoryView = l;
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    BXFloatModule *m = _rows[ip.row];
    switch (m.kind) {
        case BXModuleKindButton:
            [m fire];
            break;
        case BXModuleKindPicker: {
            if (!m.options.count) break;
            m.selectedIndex = (m.selectedIndex + 1) % m.options.count;
            [m fire];
            [self reload];
            break;
        }
        default:
            break;
    }
}

#pragma mark - 动作

- (void)_toggleChanged:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (NSInteger)_rows.count) return;
    BXFloatModule *m = _rows[(NSUInteger)sw.tag];
    m.on = sw.on;
    [m fire];
}

- (void)_sliderChanged:(UISlider *)sl {
    if (sl.tag < 0 || sl.tag >= (NSInteger)_rows.count) return;
    BXFloatModule *m = _rows[(NSUInteger)sl.tag];
    double v = sl.value;
    if (m.step > 0) v = round(v / m.step) * m.step;
    m.value = v;
    [m fire];
    UITableViewCell *cell = [_table cellForRowAtIndexPath:
                             [NSIndexPath indexPathForRow:sl.tag inSection:0]];
    cell.detailTextLabel.text = m.displayValue;
}

@end
