## iOS weak实现原理

使用weak关键字来解决循环引用的问题，原因是被weak引用的对象它的引用计数不会增加，而且这个对象被释放的时候被weak修饰的变量会自动置空，不会造成野指针的问题，相对来说会比较安全。那么**weak**底层究竟如何实现的呢

* weak的对象引用计数不增加
* weak引用对象自动置空

### weak代码定位

我们通过断点查看汇编的方式查看weak底层的调用原理

 https://user-gold-cdn.xitu.io/2020/2/18/17056a144a79a241?imageView2/0/w/1280/h/960/format/webp/ignore-error/1 

我们通过查看汇编发现`weak`底层调用的是`objc_initWeak`

 https://user-gold-cdn.xitu.io/2020/2/18/17056a144c2fa40c?imageView2/0/w/1280/h/960/format/webp/ignore-error/1 

我们给`objc_initWeak`打上符号断点重新运行，发现`objc_initWeak`存在于`libobjc.A.dylib`的动态库中。 

https://user-gold-cdn.xitu.io/2020/2/18/17056a144c7632e3?imageView2/0/w/1280/h/960/format/webp/ignore-error/1 

### 底层代码探究(保存逻辑)

#### objc_initWeak

我们在`libobjc.A.dylib`的开源代码中查找并定位到objc_initWeak函数

```c
id objc_initWeak(id *location, id newObj) {
  if (!newObj) {
    *location = nil;
    return nil;
  }
  
  return storeWeak<DontHaveOld, DoHaveNew, DoCrashIfDeallocating>(location, (objc_object*)newObj);
}
```

* 前置条件判断
* 执行`storeWeak`的存储操作

#### storeWeak

```c
assert(haveOld  ||  haveNew);
if (!haveNew) assert(newObj == nil);

Class previouslyInitializedClass = nil;
id oldObj;
SideTable *oldTable;
SideTable *newTable;
```

* 前置条件判断
* 声明新旧两个`SideTable`

```c
if (haveOld) {
  oldObj = *location;
  oldTable = &SideTables()[oldObj];
} else {
  oldTable = nil;
}
if (haveNew) {
  newTable = &SideTables()[newObj];
} else {
  newTable = nil;
}
```

* 根据新值和旧值分别获取全局的`SideTables`表，分别赋值给`oldTable`，`newTable`。

```c
if (haveNew  &&  newObj) {
    Class cls = newObj->getIsa();
    if (cls != previouslyInitializedClass  &&
        !((objc_class *)cls)->isInitialized())
    {
        SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
        class_initialize(cls, (id)newObj);

        // If this class is finished with +initialize then we re good.
        // If this class is still running +initialize on this thread
        // (i.e. +initialize called storeWeak on an instance of itself)
        // then we may proceed but it will appear initializing and
        // not yet initialized to the check above.
        // Instead set previouslyInitializedClass to recognize it on retry.
        previouslyInitializedClass = cls;

        goto retry;
    }
}
```

* 防止弱引用机制和初始化出现死锁，在弱引用之前，要确保对象已经成功初始化。

```c
// Clean up old value, if any.
if (haveOld) {
    weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
}
```

- 清空旧值。

```c
// Assign new value, if any.
if (haveNew) {
    newObj = (objc_object *)
        weak_register_no_lock(&newTable->weak_table, (id)newObj, location,
                              crashIfDeallocating);
    // weak_register_no_lock returns nil if weak store should be rejected

    // Set is-weakly-referenced bit in refcount table.
    if (newObj  &&  !newObj->isTaggedPointer()) {
        newObj->setWeaklyReferenced_nolock();
    }

    // Do not set *location anywhere else. That would introduce a race.
    *location = (id)newObj;
}
else {
    // No new value. The storage is not changed.
}
```

- 存储新值（`weak_register_no_lock`函数执行真正的存储逻辑）。

#### weak_register_no_lock

---

参数解释

- weak_table 全局的弱引用表。
- referent 弱引用对象的指针。
- referrer weak指针的地址。 省略容错的逻辑，探究主要的存储逻辑。

```c
// now remember it and where it is being stored
weak_entry_t *entry;
if ((entry = weak_entry_for_referent(weak_table, referent))) {
    append_referrer(entry, referrer);
}
else {
    // 创建了这个数组 - 插入weak_table
    weak_entry_t new_entry(referent, referrer);
    weak_grow_maybe(weak_table);
    weak_entry_insert(weak_table, &new_entry);
}
```

- 声明一个`weak_entry_t *entry;`结构体，这里保存了被若引用对象的指针，和`weak`指针的地址。
- 根据弱引用对象的指针从全局的`weak_table`中查找`entry`，如果找到了`entry`则执行插入操作。
- 通过直接操作数组中的元素来达到修改数值的目的，`weak_entry_for_referent`返回的是数组中元素的指针。
- 如果没有找到则新建一个`weak_entry_t`结构体数组，直接将这个`weak_entry_t`结构体数组插入到`weak_table`中。

### 小结

---

1. 通过SideTable找到我们的weak_table
2. weak_table 根据referent 找到或者创建 weak_entry_t 
3. 然后append_referrer(entry, referrer)将我的新弱引用的对象加进去entry
4. 最后weak_entry_insert 把entry加入到我们的weak_table

### 底层代码探究(置空逻辑)

对象的释放都在`dealloc`中，所以我们的弱引用对象的置空逻辑也应该在这里。

```c
- (void)dealloc {
    _objc_rootDealloc(self);
}




void _objc_rootDealloc(id obj)
{
    assert(obj);

    obj->rootDealloc();
}

inline void objc_object::rootDealloc()
{
    if (isTaggedPointer()) return;  // fixme necessary?

    if (fastpath(isa.nonpointer  &&  
                 !isa.weakly_referenced  &&  
                 !isa.has_assoc  &&  
                 !isa.has_cxx_dtor  &&  
                 !isa.has_sidetable_rc))
    {
        assert(!sidetable_present());
        free(this);
    } 
    else {
        object_dispose((id)this);
    }
}
```



```c
id 
object_dispose(id obj)
{
    if (!obj) return nil;

    objc_destructInstance(obj);    
    free(obj); // 内存置空

    return nil;
}
```

```c
void *objc_destructInstance(id obj) 
{
    if (obj) {
        // Read all of the flags at once for performance.
        bool cxx = obj->hasCxxDtor();
        bool assoc = obj->hasAssociatedObjects();

        // This order is important.
        if (cxx) object_cxxDestruct(obj);
        if (assoc) _object_remove_assocations(obj);
        obj->clearDeallocating();
    }

    return obj;
}
```

```c
inline void 
objc_object::clearDeallocating()
{
    if (slowpath(!isa.nonpointer)) {
        // Slow path for raw pointer isa.
        sidetable_clearDeallocating();
    }
    else if (slowpath(isa.weakly_referenced  ||  isa.has_sidetable_rc)) {
        // Slow path for non-pointer isa with weak refs and/or side table data.
        clearDeallocating_slow();
    }

    assert(!sidetable_present());
}
```

```c
NEVER_INLINE void
objc_object::clearDeallocating_slow()
{
    assert(isa.nonpointer  &&  (isa.weakly_referenced || isa.has_sidetable_rc));

    SideTable& table = SideTables()[this];
    table.lock();
    if (isa.weakly_referenced) {
        weak_clear_no_lock(&table.weak_table, (id)this);
    }
    if (isa.has_sidetable_rc) {
        table.refcnts.erase(this);
    }
    table.unlock();
}
```

```c
void 
weak_clear_no_lock(weak_table_t *weak_table, id referent_id) 
{
    objc_object *referent = (objc_object *)referent_id;

    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
    if (entry == nil) {
        /// XXX shouldn t happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        return;
    }

    // zero out references
    weak_referrer_t *referrers;
    size_t count;
    
    if (entry->out_of_line()) {
        referrers = entry->referrers;
        count = TABLE_SIZE(entry);
    } 
    else {
        referrers = entry->inline_referrers;
        count = WEAK_INLINE_COUNT;
    }
    
    for (size_t i = 0; i < count; ++i) {
        objc_object **referrer = referrers[i];
        if (referrer) {
            if (*referrer == referent) {
                *referrer = nil;
            }
            else if (*referrer) {
                _objc_inform("__weak variable at %p holds %p instead of %p. "
                             "This is probably incorrect use of "
                             "objc_storeWeak() and objc_loadWeak(). "
                             "Break on objc_weak_error to debug.\n", 
                             referrer, (void*)*referrer, (void*)referent);
                objc_weak_error();
            }
        }
    }
    
    weak_entry_remove(weak_table, entry);
}
```

* `dealloc -> _objc_rootDealloc -> rootDealloc -> object_dispose -> objc_destructInstance > clearDeallocating > clearDeallocating > clearDeallocating_slow > weak_clear_no_lock`
* 在`weak_clear_no_lock`中通过被若引用对象的指针从`weak_table`查找出对应的`weak_entry_t`结构体数组。
* 接下来循环遍历清空数组中weak指针的值，将其全部置为nil。
* 将这个结构体数组从全局的`weak_table`若引用表中移除。